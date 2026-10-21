defmodule Sinestesia.GeminiSTT do
  @moduledoc """
  Streaming STT client for Google's Gemini Live API via Mint.WebSocket.

  Built for `gemini-3.5-transcribe-live`, Google's dedicated streaming
  transcription model: audio in, `interimInputTranscription` (partials) and
  `inputTranscription` (finals) out, no model turn at all. It also speaks to a
  conversational Live model such as `gemini-3.8-live`, which only offers the
  transcript as a side channel of a voice-agent session — that model insists
  on AUDIO responses, so it is told to stay silent and anything it says is
  dropped. It is here to be measured (`mix sinestesia.bench.stt`), not because
  a voice agent is the right shape for a transcriber.

  Wire format follows the official `@google/genai` serializer, not the docs'
  prose (the docs have been wrong before — see HANDOFF): setup fields live
  under `setup`, audio goes in `realtimeInput.audio` (the legacy
  `mediaChunks` field is ignored by newer models), and the server may send its
  JSON in BINARY frames, so both frame kinds are decoded.

  Language: `GEMINI_STT_LANG` empty (the default) lets the model auto-detect
  and code-switch; a comma list of BCP-47 codes (`pt-BR,en-US`) biases it.

  A Live session is capped (~10 min for continuous streaming), which a show
  outlasts. The server announces the end with `goAway`; this client then
  reconnects on its own, buffering the audio that arrives meanwhile, so the
  pipeline never sees the seam.

  Transcripts are forwarded to the parent as
    {:transcript, :gemini, text, is_final, received_at_ms}
  """
  use GenServer
  require Logger

  @host "generativelanguage.googleapis.com"
  @port 443
  @path "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

  defp model, do: System.get_env("GEMINI_STT_MODEL", "gemini-3.5-transcribe-live")

  defp languages do
    System.get_env("GEMINI_STT_LANG", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Server-VAD silence before a phrase is finalized. Unset = the server's own
  # default. Singing holds notes and breathes in short gaps, so this is the
  # knob that trades finals-latency against phrase fragmentation.
  defp silence_ms do
    case Integer.parse(System.get_env("GEMINI_STT_SILENCE_MS", "")) do
      {ms, _} when ms > 0 -> ms
      _ -> nil
    end
  end

  # The dedicated transcriber answers in text (it never generates a turn);
  # a conversational Live model only accepts AUDIO as its response modality.
  defp transcriber?, do: String.contains?(model(), "transcribe")

  @doc "Model and language as they will be requested — for the boot banner."
  def describe, do: "#{model()} · #{lang_label()}#{silence_label()}"

  ## API

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  def send_audio(pid, bin), do: GenServer.cast(pid, {:audio, bin})

  ## Callbacks

  @impl true
  def init(parent) do
    with {:ok, key} <- api_key(),
         {:ok, conn, ref, ws} <- open(key),
         {:ok, conn, ws} <- await_setup(conn, ref, ws) do
      Logger.info(
        "[gemini] connected (model=#{model()}, lang=#{lang_label()}#{silence_label()})"
      )

      {:ok,
       %{
         parent: parent,
         key: key,
         conn: conn,
         ref: ref,
         ws: ws,
         ready: true,
         reconnecting: false,
         attempts: 0,
         pending: []
       }}
    else
      {:error, reason} ->
        Logger.error("[gemini] connect failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:audio, bin}, %{ready: false} = state) do
    # Mid-reconnect: hold the audio and replay it once the new session is up,
    # so the phrase that straddles the seam is still transcribed whole. Capped
    # at the last ~10s (40 × 250ms chunks): if the network is gone for longer
    # than that, stale audio would only arrive as a burst of stale text.
    {:noreply, %{state | pending: Enum.take([bin | state.pending], 40)}}
  end

  def handle_cast({:audio, bin}, state) do
    msg = %{
      realtimeInput: %{audio: %{data: Base.encode64(bin), mimeType: "audio/pcm;rate=16000"}}
    }

    case send_json(state, msg) do
      {:ok, state} ->
        {:noreply, state}

      {:error, state, reason} ->
        {:noreply, state |> Map.update!(:pending, &[bin | &1]) |> schedule_reconnect(reason)}
    end
  end

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, reconnect(state)}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)}

      {:error, conn, reason, responses} ->
        # Read what came with the error (the server's CLOSE frame carries
        # the code and reason) before rolling the session over; the gap is
        # reported either way, since audio sent meanwhile is lost.
        state = Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)
        Logger.warning("[gemini] stream error: #{inspect(reason)}")
        send(state.parent, {:stt_error, :gemini, {:stream_error, reason}})
        {:noreply, schedule_reconnect(state, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, ws: ws} = state) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws2, frames} ->
        Enum.reduce(frames, %{state | ws: ws2}, &handle_frame/2)

      {:error, ws2, reason} ->
        Logger.warning("[gemini] decode failed: #{inspect(reason)}")
        %{state | ws: ws2}
    end
  end

  defp handle_response({:done, ref}, %{ref: ref} = state) do
    Logger.warning("[gemini] connection done — reconnecting")
    send(state.parent, {:stt_error, :gemini, :connection_done})
    schedule_reconnect(state, :done)
  end

  defp handle_response(_other, state), do: state

  defp handle_frame({kind, payload}, state) when kind in [:text, :binary] do
    case Jason.decode(payload) do
      {:ok, msg} -> handle_message(msg, state)
      {:error, _} -> state
    end
  end

  # Mint answers nothing on its own; an unanswered ping gets the session
  # dropped by Google's frontend after a while.
  defp handle_frame({:ping, data}, state) do
    case send_frame(state, {:pong, data}) do
      {:ok, state} -> state
      {:error, state, _} -> state
    end
  end

  defp handle_frame({:close, code, reason}, state) do
    Logger.warning("[gemini] closed by server: code=#{inspect(code)} reason=#{inspect(reason)}")
    send(state.parent, {:stt_error, :gemini, {:closed_by_remote, code, reason}})
    schedule_reconnect(state, {:closed_by_remote, code})
  end

  defp handle_frame(_frame, state), do: state

  defp handle_message(%{"setupComplete" => _}, state) do
    flush_pending(%{state | ready: true, attempts: 0})
  end

  defp handle_message(%{"serverContent" => content}, state) do
    now = System.system_time(:millisecond)

    case get_in(content, ["interimInputTranscription", "text"]) do
      text when is_binary(text) and text != "" ->
        send(state.parent, {:transcript, :gemini, String.trim(text), false, now})

      _ ->
        :ok
    end

    case get_in(content, ["inputTranscription", "text"]) do
      text when is_binary(text) ->
        if String.trim(text) != "",
          do: send(state.parent, {:transcript, :gemini, String.trim(text), true, now})

      _ ->
        :ok
    end

    # Everything else the server says about the turn — turnComplete,
    # interrupted, generationComplete, a modelTurn (text, or audio from the
    # live model), outputTranscription — is the record of WHEN the model took
    # a turn, which is what explains gaps in the input transcription.
    rest = Map.drop(content, ["interimInputTranscription", "inputTranscription"])

    if rest != %{} do
      rest =
        case rest do
          %{"modelTurn" => %{"parts" => parts}} ->
            summary =
              Enum.map(parts, fn
                %{"inlineData" => %{"data" => data, "mimeType" => mt}} -> "#{mt} #{byte_size(data)}B(b64)"
                %{"text" => t} -> "text: " <> String.slice(t, 0, 120)
                p -> inspect(p) |> String.slice(0, 120)
              end)

            Map.put(rest, "modelTurn", summary)

          _ ->
            rest
        end

      Logger.info("[gemini] turn: #{Jason.encode!(rest) |> String.slice(0, 400)}")
    end

    state
  end

  # The session is about to hit its time cap — swap to a fresh one now,
  # while the old one is still answering, instead of after it drops.
  defp handle_message(%{"goAway" => info}, state) do
    Logger.warning("[gemini] goAway #{inspect(info)} — rolling over to a new session")
    # Audio sent while the new session sets up is buffered (then capped), so
    # a rollover is still a gap worth recording on a bench row.
    send(state.parent, {:stt_error, :gemini, {:go_away, info}})
    schedule_reconnect(state, :go_away)
  end

  defp handle_message(%{"error" => err}, state) do
    send(state.parent, {:stt_error, :gemini, err})
    state
  end

  # Usage metadata, session resumption, anything new: nothing the pipeline
  # needs, but it is what explains a session's behaviour when probing a model
  # (`mix sinestesia.bench.stt --verbose`), so it is logged in full at info.
  defp handle_message(other, state) do
    Logger.info("[gemini] server: #{other |> Jason.encode!() |> String.slice(0, 600)}")
    state
  end

  ## Reconnect

  # One reconnect in flight at a time: a dying socket reports itself several
  # ways at once (goAway, close frame, :done), and each would otherwise open
  # its own replacement session.
  defp schedule_reconnect(%{reconnecting: true} = state, _reason), do: state

  # Immediately after a healthy session (a goAway rollover must be seamless),
  # then backing off: a session the server keeps refusing — bad key, quota,
  # a model name it no longer knows — must not become a reconnect storm.
  defp schedule_reconnect(state, reason) do
    delay = if state.attempts == 0, do: 0, else: min(500 * Integer.pow(2, state.attempts), 10_000)
    Logger.info("[gemini] reconnecting in #{delay}ms (#{inspect(reason)})")
    Process.send_after(self(), :reconnect, delay)
    %{state | ready: false, reconnecting: true, attempts: state.attempts + 1}
  end

  defp reconnect(state) do
    Mint.HTTP.close(state.conn)

    case open(state.key) do
      {:ok, conn, ref, ws} ->
        # setupComplete arrives through handle_info; audio buffers until then.
        %{state | conn: conn, ref: ref, ws: ws, ready: false, reconnecting: false}

      {:error, err} ->
        Logger.error("[gemini] reconnect failed: #{inspect(err)}")
        send(state.parent, {:stt_error, :gemini, {:reconnect_failed, err}})
        schedule_reconnect(%{state | reconnecting: false}, err)
    end
  end

  defp flush_pending(%{pending: []} = state), do: state

  defp flush_pending(state) do
    chunks = Enum.reverse(state.pending)
    state = %{state | pending: []}

    Enum.reduce(chunks, state, fn bin, st ->
      {:noreply, st} = handle_cast({:audio, bin}, st)
      st
    end)
  end

  ## Connection

  defp setup_message do
    transcription =
      case languages() do
        [] -> %{}
        codes -> %{languageCodes: codes}
      end

    vad =
      case silence_ms() do
        nil -> %{}
        ms -> %{realtimeInputConfig: %{automaticActivityDetection: %{silenceDurationMs: ms}}}
      end

    model_cfg =
      if transcriber?() do
        %{generationConfig: %{responseModalities: ["TEXT"]}}
      else
        %{
          generationConfig: %{responseModalities: ["AUDIO"]},
          systemInstruction: %{
            parts: [
              %{
                text:
                  "You are a silent listener at a concert. Never speak, never reply, never sing along."
              }
            ]
          }
        }
      end

    %{
      setup:
        %{model: "models/" <> model(), inputAudioTranscription: transcription}
        |> Map.merge(model_cfg)
        |> Map.merge(vad)
    }
  end

  defp open(key) do
    with {:ok, conn} <-
           Mint.HTTP.connect(:https, @host, @port,
             protocols: [:http1],
             transport_opts: [verify: :verify_none]
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:wss, conn, @path <> "?key=" <> key, []),
         {:ok, conn, ws} <- await_upgrade(conn, ref),
         {:ok, st} <- send_json(%{conn: conn, ref: ref, ws: ws}, setup_message()) do
      {:ok, st.conn, ref, st.ws}
    else
      {:error, _conn_or_state, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # Init only: block until the model accepts the setup, so a bad key or model
  # name fails the provider at start (where the operator sees it) instead of
  # as silence later.
  defp await_setup(conn, ref, ws) do
    receive do
      message when is_tuple(message) and elem(message, 0) in [:ssl, :tcp, :ssl_closed, :tcp_closed] ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            frames =
              Enum.flat_map(responses, fn
                {:data, ^ref, data} ->
                  case Mint.WebSocket.decode(ws, data) do
                    {:ok, _ws, frames} -> frames
                    _ -> []
                  end

                _ ->
                  []
              end)

            cond do
              Enum.any?(frames, &setup_complete?/1) ->
                {:ok, conn, ws}

              close = Enum.find(frames, &match?({:close, _, _}, &1)) ->
                {:error, {:setup_rejected, close}}

              true ->
                await_setup(conn, ref, ws)
            end

          {:error, _conn, reason, _} ->
            {:error, reason}
        end
    after
      8_000 -> {:error, :setup_timeout}
    end
  end

  defp setup_complete?({kind, payload}) when kind in [:text, :binary] do
    match?({:ok, %{"setupComplete" => _}}, Jason.decode(payload))
  end

  defp setup_complete?(_), do: false

  defp send_json(state, msg), do: send_frame(state, {:text, Jason.encode!(msg)})

  defp send_frame(%{conn: conn, ref: ref, ws: ws} = state, frame) do
    case Mint.WebSocket.encode(ws, frame) do
      {:ok, ws, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn} -> {:ok, %{state | conn: conn, ws: ws}}
          {:error, conn, reason} -> {:error, %{state | conn: conn, ws: ws}, reason}
        end

      {:error, ws, reason} ->
        {:error, %{state | ws: ws}, reason}
    end
  end

  # Selective receive: during a mid-show reconnect this runs inside the
  # GenServer, and a catch-all receive would swallow the audio casts queued
  # behind the socket messages.
  defp await_upgrade(conn, ref, status \\ nil, headers \\ []) do
    receive do
      message when is_tuple(message) and elem(message, 0) in [:ssl, :tcp, :ssl_closed, :tcp_closed] ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status =
              Enum.find_value(responses, status, fn
                {:status, ^ref, s} -> s
                _ -> nil
              end)

            headers =
              headers ++
                Enum.flat_map(responses, fn
                  {:headers, ^ref, h} -> h
                  _ -> []
                end)

            if status && Enum.any?(responses, &match?({:headers, ^ref, _}, &1)) do
              Mint.WebSocket.new(conn, ref, status, headers)
            else
              await_upgrade(conn, ref, status, headers)
            end

          {:error, conn, reason, _} ->
            {:error, conn, reason}
        end
    after
      5_000 -> {:error, :upgrade_timeout}
    end
  end

  defp api_key do
    cfg = Application.get_env(:sinestesia, :config, [])

    case Keyword.get(cfg, :google_api_key) || System.get_env("GOOGLE_API_KEY") do
      k when is_binary(k) and k != "" -> {:ok, k}
      _ -> {:error, :no_api_key}
    end
  end

  defp lang_label do
    case languages() do
      [] -> "auto"
      codes -> Enum.join(codes, ",")
    end
  end

  defp silence_label do
    case silence_ms() do
      nil -> ""
      ms -> ", silence=#{ms}ms"
    end
  end
end
