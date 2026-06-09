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

  # Story mode runs slower on purpose: img2img is ~1.5s vs t2i's ~500ms, and
  # we want each new element to land deliberately rather than flashing past.
  defp director_min_interval_ms do
    case Sinestesia.Director.mode() do
      :story -> 5000
      _ -> 3000
    end
  end

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
        if Process.alive?(old_pid), do: kill_previous(old_pid)

      _ ->
        :ok
    end
  end

  # Robustly take down the old pipeline before starting a new one. We MUST
  # wait until it's actually dead (and deregistered from the Registry),
  # otherwise the new start_link races and falls into {:already_started, _}.
  # That used to make AudioSocket "adopt" a corpse pid.
  #
  # Sequence: monitor → :shutdown → wait up to 4s. If still alive (pipeline
  # may be blocked in init waiting for ElevenSTT WS handshake), hard-kill.
  defp kill_previous(old_pid) do
    Logger.info("pipeline: stopping previous active pipeline #{inspect(old_pid)}")
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^old_pid, _} ->
        :ok
    after
      4_000 ->
        Logger.warning("pipeline: previous didn't die in 4s, hard-killing #{inspect(old_pid)}")
        Process.exit(old_pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^old_pid, _} -> :ok
        after
          1_000 ->
            Logger.error("pipeline: hard-kill timed out for #{inspect(old_pid)}")
            :ok
        end
    end
  end
  def audio_chunk(pid, bin), do: GenServer.cast(pid, {:audio_chunk, bin})
  def expressive(pid, features), do: GenServer.cast(pid, {:expressive, features})
  def fast_features(pid, features), do: GenServer.cast(pid, {:fast_features, features})
  def set_style(pid, style), do: GenServer.cast(pid, {:set_style, style})
  def reset_song(pid), do: GenServer.cast(pid, :reset_song)

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
       since_last_director: false,
       last_image_url: nil,
       bootstrap_done?: false,
       # Bumped on every reset_song. Any in-flight Task (director / image /
       # curator) captures the session_id at spawn; results carrying an older
       # session_id are dropped on receive so old-song work can't leak into
       # the new song. Belt + suspenders alongside pending_pids below.
       session_id: 0,
       # PIDs of every in-flight Task (director / image / curator). Killed
       # on reset so we stop paying fal.ai / running Gemma for old-song work.
       pending_pids: MapSet.new()
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

  # Reset all song-scoped state but KEEP open STT connections + socket.
  # Use when a new song starts mid-session — avoids reconnect roundtrip.
  # In-flight tasks from the previous song are invalidated via session_id.
  def handle_cast(:reset_song, state) do
    new_session = state.session_id + 1
    killed = kill_pending(state.pending_pids)

    Logger.info(
      "[pipeline] song reset — session_id #{state.session_id} → #{new_session}, killed #{killed} in-flight task(s)"
    )

    default_style = Sinestesia.Director.default_style()

    push(state.socket, %{
      type: "style",
      style: default_style,
      source: "reset",
      ts: now_ms()
    })

    {:noreply,
     %{
       state
       | lyrics: [],
         last_finals: %{},
         last_interims: %{},
         last_text_at: %{},
         last_director_text: "",
         style: default_style,
         style_locked?: false,
         final_lyric_count: 0,
         director_conversation: Sinestesia.Director.init_conversation(),
         last_director_at: 0,
         last_stt_ms: nil,
         last_stt_provider: nil,
         # Critical: clear generating? so the next director call isn't blocked
         # waiting for an in-flight (now-stale) task that we're about to drop.
         generating?: false,
         since_last_director: false,
         last_image_url: nil,
         bootstrap_done?: false,
         session_id: new_session,
         pending_pids: MapSet.new()
     }}
  end

  defp kill_pending(pids) do
    Enum.reduce(pids, 0, fn pid, acc ->
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
        acc + 1
      else
        acc
      end
    end)
  end

  # Sweep out PIDs that have already completed. Called from each handle_info
  # so the set doesn't grow unbounded across a long session.
  defp drop_dead(pids) do
    pids |> Enum.filter(&Process.alive?/1) |> Enum.into(MapSet.new())
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

  def handle_info({:director_done, _result, _started_at, sid}, %{session_id: cur} = state)
      when sid != cur do
    Logger.info("[director] dropping stale result (session #{sid} ≠ #{cur})")
    {:noreply, state}
  end

  def handle_info({:director_done, {:ok, prompt, new_conversation}, started_at, _sid}, state) do
    director_ms = now_ms() - started_at
    Logger.info("[director] +#{director_ms}ms (#{turn_count(new_conversation)} turns): #{prompt}")

    timings = %{
      stt_ms: state.last_stt_ms,
      stt_provider: state.last_stt_provider,
      director_ms: director_ms
    }

    img_pid = spawn_image(prompt, timings, state.last_image_url, state.session_id)

    pids =
      state.pending_pids
      |> drop_dead()
      |> MapSet.put(img_pid)

    {:noreply,
     %{state | generating?: true, director_conversation: new_conversation, bootstrap_done?: true, pending_pids: pids}}
  end

  def handle_info({:director_done, {:error, reason}, _started_at, _sid}, state) do
    Logger.warning("[director] error: #{inspect(reason)}")
    {:noreply, %{state | generating?: false, pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info({:image_done, _result, _timings, sid}, %{session_id: cur} = state)
      when sid != cur do
    Logger.info("[image] dropping stale result (session #{sid} ≠ #{cur})")
    {:noreply, state}
  end

  def handle_info({:image_done, {:ok, url, prompt}, timings, _sid}, state) do
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

    {:noreply, %{state | generating?: false, last_image_url: url, pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info({:image_done, {:error, reason}, _timings, _sid}, state) do
    Logger.warning("[image] error: #{inspect(reason)}")
    {:noreply, %{state | generating?: false, pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info({:style_curated, _result, sid}, %{session_id: cur} = state)
      when sid != cur do
    Logger.info("[curator] dropping stale result (session #{sid} ≠ #{cur})")
    {:noreply, state}
  end

  def handle_info({:style_curated, {:ok, style}, _sid}, state) do
    Logger.info("[curator] picked style: #{style}")
    apply_style(state, style, _from_curator? = true)
  end

  def handle_info({:style_curated, {:error, reason}, _sid}, state) do
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
    pid = spawn_curator(state)
    # Optimistically lock so we don't double-fire; unlock if curator fails
    %{state | style_locked?: true, pending_pids: MapSet.put(state.pending_pids, pid)}
  end

  defp maybe_curate_style(state), do: state

  defp spawn_curator(state) do
    parent = self()
    lyrics = state.lyrics
    expressive = state.expressive
    sid = state.session_id

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:style_curated, Sinestesia.StyleCurator.curate(lyrics, expressive), sid})
      end)

    pid
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
           last_director_text: "",
           last_image_url: nil
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

    cond do
      same_as_before? ->
        state

      is_final ->
        # StyleCurator is intentionally NOT invoked here. We tried auto-picking
        # the style after N lyrics, but it kept overwriting the front-end's
        # style input mid-song. Style is now driven 100% by the operator typing
        # in the front, or by the IMAGE_MODE default at session/reset.
        %{
          state
          | lyrics: state.lyrics ++ [text],
            last_interims: Map.put(state.last_interims, provider, text),
            last_finals: Map.put(state.last_finals, provider, text),
            last_text_at: Map.put(state.last_text_at, provider, now_ms()),
            last_stt_ms: latency,
            last_stt_provider: provider,
            final_lyric_count: state.final_lyric_count + 1,
            since_last_director: true
        }

      true ->
        %{
          state
          | last_interims: Map.put(state.last_interims, provider, text),
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
      "all" -> [:elevenlabs, :deepgram, :local_whisper]
      "deepgram" -> [:deepgram]
      "local_whisper" -> [:local_whisper]
      "local" -> [:local_whisper]
      # A/B compare ElevenLabs against local Whisper in the same session
      "eleven_local" -> [:elevenlabs, :local_whisper]
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

  defp start_stt(:local_whisper, socket_pid) do
    case Sinestesia.LocalWhisperSTT.start_link(self()) do
      {:ok, pid} ->
        Logger.info("[local_whisper] started")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[local_whisper] disabled: #{inspect(reason)} (is the sidecar running on :8002?)")
        send(socket_pid, {:push_json, %{type: "error", message: "local_whisper disabled: #{inspect(reason)}"}})
        {:error, reason}
    end
  end

  defp send_audio(:elevenlabs, pid, bin), do: Sinestesia.ElevenSTT.send_audio(pid, bin)
  defp send_audio(:deepgram, pid, bin), do: Sinestesia.Deepgram.send_audio(pid, bin)
  defp send_audio(:local_whisper, pid, bin), do: Sinestesia.LocalWhisperSTT.send_audio(pid, bin)

  # Bootstrap (first image): wait for a richer prompt so the opening drawing
  # has enough substance. With img2img strength 0.8 the first image dominates
  # the rest of the song, so it must NOT be drawn from 4-5 words alone.
  @bootstrap_min_words 15
  # Word window for the first Director call (vs @window_words=10 for subsequent).
  @bootstrap_window_words 30
  # Default window for subsequent calls. Defined here (NOT later) because Elixir
  # module attributes are not hoisted — used in maybe_trigger below.
  @window_words 10

  defp maybe_trigger(%{generating?: true} = state), do: state
  defp maybe_trigger(%{since_last_director: false} = state), do: state

  defp maybe_trigger(state) do
    now = now_ms()
    bootstrap? = bootstrap?(state)

    cond do
      bootstrap? and accumulated_word_count(state) < @bootstrap_min_words ->
        # Wait until enough has been sung to seed a rich opening drawing.
        state

      now - state.last_director_at < director_min_interval_ms() ->
        state

      true ->
        # Bootstrap input: ALL accumulated finals + current interim. The gate
        # already saw 15+ words cumulatively, but pick_current_line only sees
        # the latest interim — which ElevenLabs VAD resets to a few words
        # after each commit. Sending that alone gives the model 4 words and
        # it confabulates (asks for the song title, etc).
        text =
          if bootstrap? do
            bootstrap_text(state, @bootstrap_window_words)
          else
            pick_current_line(state, @window_words)
          end

        cond do
          text == "" ->
            state

          text == state.last_director_text ->
            Logger.debug("[director] skip duplicate: #{inspect(text)}")
            %{state | since_last_director: false}

          true ->
            if bootstrap?, do: Logger.info("[director] bootstrap fire with #{word_count(text)} words: #{inspect(text)}")
            pid = spawn_director(state, text)

            %{
              state
              | last_director_at: now,
                since_last_director: false,
                generating?: true,
                last_director_text: text,
                pending_pids: MapSet.put(state.pending_pids, pid)
            }
        end
    end
  end

  # Build the bootstrap input by joining ALL final lyrics so far + the latest
  # interim (if it isn't already a final), then taking the trailing N words.
  defp bootstrap_text(state, window) do
    finals = state.lyrics |> Enum.join(" ")

    latest_interim =
      state.last_interims
      |> Map.values()
      |> Enum.reject(&(&1 == "" or &1 in state.lyrics))
      |> Enum.max_by(&word_count/1, fn -> "" end)

    [finals, latest_interim]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> last_n_words(window)
  end

  # Bootstrap (initial rich-opening gate) only applies ONCE per session —
  # the very first Director call. We do NOT re-enter bootstrap after a style
  # change, because by then the singer is mid-song and we'd lock up waiting
  # for word counts that already exist.
  defp bootstrap?(state), do: not state.bootstrap_done?

  # Count words across ALL final lyrics so far. Counting interims is unreliable:
  # ElevenLabs in VAD mode commits and RESETS the interim after each segment,
  # so an interim alone never grows past one line. We need cumulative finals.
  defp accumulated_word_count(state) do
    finals = state.lyrics |> Enum.map(&word_count/1) |> Enum.sum()

    # Add the current interim ONLY if it's not already covered by the last final
    # (avoid double-counting when the interim equals the just-committed line).
    interim_extra =
      state.last_interims
      |> Map.values()
      |> Enum.map(fn t ->
        if t in state.lyrics, do: 0, else: word_count(t)
      end)
      |> Enum.max(fn -> 0 end)

    finals + interim_extra
  end

  defp word_count(text) when is_binary(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp word_count(_), do: 0

  defp spawn_director(state, text) do
    parent = self()
    started_at = now_ms()
    conversation = state.director_conversation
    sid = state.session_id
    Logger.debug("[director] spawning (current line: #{inspect(text)})")

    {:ok, pid} =
      Task.start(fn ->
        result = Sinestesia.Director.next_prompt(conversation, text)
        send(parent, {:director_done, result, started_at, sid})
      end)

    pid
  end

  defp turn_count(conversation) do
    # Each user turn = one exchange. System counts as 0.
    Enum.count(conversation, &(&1.role == "user"))
  end

  defp pick_current_line(state, window \\ @window_words) do
    # Pick the text from whichever provider updated MOST RECENTLY, then take
    # the trailing N words. This is robust to both segmenting providers
    # (Deepgram → short fragment, we keep all) and accumulating providers
    # (ElevenLabs → long running transcript, we keep only the end).
    state.last_text_at
    |> Enum.map(fn {provider, ts} ->
      raw = Map.get(state.last_interims, provider, "")
      {ts, last_n_words(raw, window)}
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


  defp spawn_image(prompt, timings, prev_url, sid) do
    parent = self()
    timings = Map.put(timings, :image_started_at, now_ms())

    opts = if is_binary(prev_url) and prev_url != "", do: [image_url: prev_url], else: []

    {:ok, pid} =
      Task.start(fn ->
        result =
          case Sinestesia.ImageGen.generate(prompt, opts) do
            {:ok, url} -> {:ok, url, prompt}
            err -> err
          end

        send(parent, {:image_done, result, timings, sid})
      end)

    pid
  end

  defp push(socket, msg), do: send(socket, {:push_json, msg})
  defp now_ms, do: System.system_time(:millisecond)
end
