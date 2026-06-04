defmodule Sinestesia.Pipeline do
  @moduledoc """
  Per-socket GenServer. Orchestrates the three rails:

    * receives audio chunks from the socket, fans out to one or more STT providers
    * collects transcripts (tagged with provider), pushes them back to the socket
    * collects expressive features from the socket
    * debounces Director calls (Gemma → image prompt → fal.ai → URL → socket)

  STT provider selection via `STT_PROVIDER` env var:
    "elevenlabs"  → ElevenLabs Scribe v2 Realtime only (default)
    "deepgram"    → Deepgram Nova-3 only
    "both"        → both run in parallel; transcripts logged side-by-side
                    for A/B comparison. The first to deliver each final
                    transcript wins for the Director.
  """
  use GenServer
  require Logger

  @director_min_interval_ms 3000

  ## API

  def start_link(socket_pid) do
    # Only one Pipeline at a time globally. Synchronously stop any previous one
    # so the Registry slot is free before we try to register the new pipeline.
    stop_previous()

    GenServer.start_link(__MODULE__, socket_pid,
      name: {:via, Registry, {Sinestesia.PipelineRegistry, :active}}
    )
  end

  defp stop_previous do
    case Registry.lookup(Sinestesia.PipelineRegistry, :active) do
      [{old_pid, _}] when is_pid(old_pid) ->
        if Process.alive?(old_pid) do
          Logger.info("pipeline: stopping previous active pipeline #{inspect(old_pid)}")

          try do
            GenServer.stop(old_pid, :shutdown, 1_000)
          catch
            :exit, _ -> :ok
          end
        end

      _ ->
        :ok
    end
  end
  def audio_chunk(pid, bin), do: GenServer.cast(pid, {:audio_chunk, bin})
  def expressive(pid, features), do: GenServer.cast(pid, {:expressive, features})
  def fast_features(pid, features), do: GenServer.cast(pid, {:fast_features, features})
  def set_style(pid, style), do: GenServer.cast(pid, {:set_style, style})

  ## Callbacks

  @impl true
  def init(socket_pid) do
    Process.flag(:trap_exit, true)
    providers = which_providers()
    stts = start_stts(providers, socket_pid)

    {:ok,
     %{
       socket: socket_pid,
       stts: stts,
       lyrics: [],
       last_finals: %{},
       last_interims: %{},
       last_text_at: %{},
       last_director_text: "",
       style: Sinestesia.Director.default_style(),
       style_locked?: false,
       final_lyric_count: 0,
       director_conversation: Sinestesia.Director.init_conversation(),
       expressive: %{},
       fast: %{},
       last_director_at: 0,
       last_audio_chunk_at: 0,
       last_stt_ms: nil,
       last_stt_provider: nil,
       generating?: false,
       since_last_director: false
     }}
  end

  @impl true
  def handle_cast({:audio_chunk, bin}, %{stts: stts} = state) do
    Enum.each(stts, fn {provider, pid} -> send_audio(provider, pid, bin) end)
    {:noreply, %{state | last_audio_chunk_at: System.system_time(:millisecond)}}
  end

  def handle_cast({:expressive, f}, state) do
    {:noreply, %{state | expressive: f} |> maybe_trigger()}
  end

  def handle_cast({:fast_features, f}, state) do
    {:noreply, %{state | fast: f}}
  end

  def handle_cast({:set_style, raw_style}, state) do
    apply_style(state, raw_style, _from_curator? = false)
  end

  @impl true
  def handle_info({:transcript, provider, text, is_final, recv_ts}, state) do
    latency = recv_ts - state.last_audio_chunk_at
    tag = if is_final, do: "FIN", else: "int"

    Logger.info("[#{provider}] #{tag} +#{latency}ms: #{text}")

    push(state.socket, %{
      type: "transcript",
      provider: provider,
      text: text,
      is_final: is_final,
      latency_ms: latency,
      ts: recv_ts
    })

    state = update_text_state(state, provider, text, is_final, latency)
    {:noreply, maybe_trigger(state)}
  end

  def handle_info({:stt_error, provider, reason}, state) do
    push(state.socket, %{
      type: "error",
      provider: provider,
      message: "#{provider}: #{inspect(reason)}"
    })

    {:noreply, state}
  end

  def handle_info({:director_done, {:ok, prompt, new_conversation}, started_at}, state) do
    director_ms = now_ms() - started_at
    Logger.info("[director] +#{director_ms}ms (#{turn_count(new_conversation)} turns): #{prompt}")

    timings = %{
      stt_ms: state.last_stt_ms,
      stt_provider: state.last_stt_provider,
      director_ms: director_ms
    }

    spawn_image(prompt, timings)
    {:noreply, %{state | generating?: true, director_conversation: new_conversation}}
  end

  def handle_info({:director_done, {:error, reason}, _started_at}, state) do
    Logger.warning("[director] error: #{inspect(reason)}")
    {:noreply, %{state | generating?: false}}
  end

  def handle_info({:image_done, {:ok, url, prompt}, timings}, state) do
    image_ms = now_ms() - timings.image_started_at
    provider = Sinestesia.ImageGen.provider() |> to_string()
    total = (timings.stt_ms || 0) + timings.director_ms + image_ms

    Logger.info(
      "[image:#{provider}] +#{image_ms}ms (total #{total}ms = stt #{timings.stt_ms || 0} + director #{timings.director_ms} + image #{image_ms})"
    )

    push(state.socket, %{
      type: "image",
      url: url,
      prompt: prompt,
      ts: now_ms(),
      timings: %{
        stt_ms: timings.stt_ms,
        stt_provider: timings.stt_provider,
        director_ms: timings.director_ms,
        image_ms: image_ms,
        total_ms: total,
        image_provider: provider
      }
    })

    {:noreply, %{state | generating?: false}}
  end

  def handle_info({:image_done, {:error, reason}, _timings}, state) do
    Logger.warning("[image] error: #{inspect(reason)}")
    {:noreply, %{state | generating?: false}}
  end

  def handle_info({:style_curated, {:ok, style}}, state) do
    Logger.info("[curator] picked style: #{style}")
    apply_style(state, style, _from_curator? = true)
  end

  def handle_info({:style_curated, {:error, reason}}, state) do
    Logger.warning("[curator] failed (#{inspect(reason)}); keeping current style")
    # Don't relock — allow retry on next batch of lyrics
    {:noreply, %{state | style_locked?: false}}
  end

  def handle_info({:EXIT, pid, reason}, %{socket: socket} = state) when pid == socket do
    Logger.info("pipeline: socket exited (#{inspect(reason)}); shutting down")
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.stts, fn {_p, p_pid} -> p_pid == pid end) do
      {provider, _} ->
        Logger.warning("[#{provider}] exited (#{inspect(reason)}); attempting restart")

        new_stts =
          case start_stt(provider, state.socket) do
            {:ok, new_pid} -> Map.put(state.stts, provider, new_pid)
            _ -> Map.delete(state.stts, provider)
          end

        {:noreply, %{state | stts: new_stts}}

      nil ->
        Logger.debug("pipeline: ignored EXIT from #{inspect(pid)} (#{inspect(reason)})")
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.info("pipeline: terminating (#{inspect(reason)})")

    Enum.each(state.stts, fn {_provider, pid} ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    :ok
  end

  ## Internals

  @curator_trigger_count 5

  defp maybe_curate_style(%{style_locked?: true} = state), do: state

  defp maybe_curate_style(%{final_lyric_count: n} = state) when n >= @curator_trigger_count do
    Logger.info("[curator] firing after #{n} final lyrics")
    spawn_curator(state)
    # Optimistically lock so we don't double-fire; unlock if curator fails
    %{state | style_locked?: true}
  end

  defp maybe_curate_style(state), do: state

  defp spawn_curator(state) do
    parent = self()
    lyrics = state.lyrics
    expressive = state.expressive

    Task.start(fn ->
      send(parent, {:style_curated, Sinestesia.StyleCurator.curate(lyrics, expressive)})
    end)
  end

  defp apply_style(state, raw_style, from_curator?) do
    new_style = Sinestesia.Director.sanitize_style(raw_style)

    if new_style == state.style do
      # Same style — but if from curator, mark as locked so we don't fire again
      {:noreply, if(from_curator?, do: %{state | style_locked?: true}, else: state)}
    else
      tag = if from_curator?, do: "[curator]", else: "[style]"
      Logger.info("#{tag} #{inspect(state.style)} → #{inspect(new_style)} (resetting conversation)")

      push(state.socket, %{
        type: "style",
        style: new_style,
        source: if(from_curator?, do: "curator", else: "user"),
        ts: now_ms()
      })

      {:noreply,
       %{
         state
         | style: new_style,
           style_locked?: true,
           director_conversation: Sinestesia.Director.init_conversation(new_style),
           last_director_text: ""
       }}
    end
  end

  defp update_text_state(state, _provider, "", _is_final, _latency), do: state

  defp update_text_state(state, provider, text, is_final, latency) do
    prev_interim = Map.get(state.last_interims, provider, "")
    prev_final = Map.get(state.last_finals, provider, "")

    same_as_before? =
      (is_final and text == prev_final) or
        (not is_final and text == prev_interim)

    if same_as_before? do
      state
    else
      %{
        state
        | lyrics: if(is_final, do: state.lyrics ++ [text], else: state.lyrics),
          last_interims: Map.put(state.last_interims, provider, text),
          last_finals:
            if(is_final, do: Map.put(state.last_finals, provider, text), else: state.last_finals),
          last_text_at: Map.put(state.last_text_at, provider, now_ms()),
          last_stt_ms: latency,
          last_stt_provider: provider,
          since_last_director: true
      }
    end
  end

  defp which_providers do
    case System.get_env("STT_PROVIDER", "elevenlabs") |> String.downcase() do
      "both" -> [:elevenlabs, :deepgram]
      "deepgram" -> [:deepgram]
      _ -> [:elevenlabs]
    end
  end

  defp start_stts(providers, socket_pid) do
    Enum.reduce(providers, %{}, fn provider, acc ->
      case start_stt(provider, socket_pid) do
        {:ok, pid} -> Map.put(acc, provider, pid)
        _ -> acc
      end
    end)
  end

  defp start_stt(:elevenlabs, socket_pid) do
    case Sinestesia.ElevenSTT.start_link(self()) do
      {:ok, pid} ->
        Logger.info("[elevenlabs] started")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[elevenlabs] disabled: #{inspect(reason)}")
        send(socket_pid, {:push_json, %{type: "error", message: "elevenlabs disabled: #{inspect(reason)}"}})
        {:error, reason}
    end
  end

  defp start_stt(:deepgram, socket_pid) do
    case Sinestesia.Deepgram.start_link(self()) do
      {:ok, pid} ->
        Logger.info("[deepgram] started")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[deepgram] disabled: #{inspect(reason)}")
        send(socket_pid, {:push_json, %{type: "error", message: "deepgram disabled: #{inspect(reason)}"}})
        {:error, reason}
    end
  end

  defp send_audio(:elevenlabs, pid, bin), do: Sinestesia.ElevenSTT.send_audio(pid, bin)
  defp send_audio(:deepgram, pid, bin), do: Sinestesia.Deepgram.send_audio(pid, bin)

  defp maybe_trigger(%{generating?: true} = state), do: state
  defp maybe_trigger(%{since_last_director: false} = state), do: state

  defp maybe_trigger(state) do
    now = now_ms()

    cond do
      now - state.last_director_at < @director_min_interval_ms ->
        state

      true ->
        case pick_current_line(state) do
          "" ->
            # No usable text yet (e.g. "..." or punctuation only). Wait.
            state

          text when text == state.last_director_text ->
            # Same content as last call — don't waste a Director cycle.
            Logger.debug("[director] skip duplicate: #{inspect(text)}")
            %{state | since_last_director: false}

          text ->
            spawn_director(state, text)

            %{
              state
              | last_director_at: now,
                since_last_director: false,
                generating?: true,
                last_director_text: text
            }
        end
    end
  end

  defp spawn_director(state, text) do
    parent = self()
    started_at = now_ms()
    conversation = state.director_conversation
    Logger.debug("[director] spawning (current line: #{inspect(text)})")

    Task.start(fn ->
      result = Sinestesia.Director.next_prompt(conversation, text)
      send(parent, {:director_done, result, started_at})
    end)
  end

  defp turn_count(conversation) do
    # Each user turn = one exchange. System counts as 0.
    Enum.count(conversation, &(&1.role == "user"))
  end

  @window_words 10

  defp pick_current_line(state) do
    # Pick the text from whichever provider updated MOST RECENTLY, then take
    # the trailing N words. This is robust to both segmenting providers
    # (Deepgram → short fragment, we keep all) and accumulating providers
    # (ElevenLabs → long running transcript, we keep only the end).
    state.last_text_at
    |> Enum.map(fn {provider, ts} ->
      raw = Map.get(state.last_interims, provider, "")
      {ts, last_n_words(raw, @window_words)}
    end)
    |> Enum.reject(fn {_, text} -> text == "" end)
    |> case do
      [] ->
        ""

      candidates ->
        {_ts, text} = Enum.max_by(candidates, fn {ts, _} -> ts end)
        text
    end
  end

  defp last_n_words(text, n) when is_binary(text) do
    text
    |> String.trim()
    |> String.trim_leading(".")
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(-n)
    |> Enum.join(" ")
    |> String.trim_trailing(".")
    |> String.trim_trailing(",")
    |> String.trim_trailing("-")
  end

  defp last_n_words(_, _), do: ""


  defp spawn_image(prompt, timings) do
    parent = self()
    timings = Map.put(timings, :image_started_at, now_ms())

    Task.start(fn ->
      result =
        case Sinestesia.ImageGen.generate(prompt) do
          {:ok, url} -> {:ok, url, prompt}
          err -> err
        end

      send(parent, {:image_done, result, timings})
    end)
  end

  defp push(socket, msg), do: send(socket, {:push_json, msg})
  defp now_ms, do: System.system_time(:millisecond)
end
