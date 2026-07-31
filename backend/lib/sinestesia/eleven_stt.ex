defmodule Sinestesia.ElevenSTT do
  @moduledoc """
  Streaming STT client using ElevenLabs Scribe v2 Realtime via Mint.WebSocket.

  Sub-150ms latency, Portuguese with <5% WER. Audio is 16-bit LE PCM 16kHz mono,
  sent as JSON text frames with base64-encoded payload (per ElevenLabs spec).

  Transcripts are forwarded to the parent process as:
    {:transcript, text, is_final}
  """
  use GenServer
  require Logger

  @host "api.elevenlabs.io"
  @port 443

  # Tunable via env vars to debug protocol mismatches without recompiling much:
  #   ELEVEN_MODEL    (default "scribe_v2_realtime")
  #   ELEVEN_LANG     (default "pt" — try "por", "pt-BR", or "" to disable)
  #   ELEVEN_COMMIT   (default "vad", or "manual" to commit every chunk)
  #   ELEVEN_NO_VERBATIM (unset; "1"/"true"/"on" asks Scribe to clean the text)
  defp path do
    model = System.get_env("ELEVEN_MODEL", "scribe_v2_realtime")
    lang = System.get_env("ELEVEN_LANG", "pt")
    commit = System.get_env("ELEVEN_COMMIT", "vad")
    # Default 1.5s makes Eleven hold transcripts forever during continuous singing.
    # 0.6s is enough to detect breath gaps without false segmentation mid-phrase.
    vad_silence = System.get_env("ELEVEN_VAD_SILENCE", "0.6")

    base =
      "/v1/speech-to-text/realtime?model_id=#{model}&audio_format=pcm_16000&commit_strategy=#{commit}&vad_silence_threshold_secs=#{vad_silence}"

    base
    |> then(&if(lang == "", do: &1, else: &1 <> "&language_code=#{lang}"))
    |> then(&if(no_verbatim?(), do: &1 <> "&no_verbatim=true", else: &1))
  end

  # Scribe's "no verbatim" mode. OFF by default and deliberately so — its
  # documented job is removing filler words, REPEATED PHRASES and stuttering,
  # and a song is repetitive on purpose. A mode that strips repeats could eat
  # the second occurrence of a chorus, which is exactly the signal
  # PerformanceFollower needs to know where in the song we are. It is exposed
  # because it may still clean up the false starts a live mic produces
  # ("Isso é fácil chover" before "E se faço chover"), and that is worth
  # measuring on a real run — but it is NOT the fix for held vowels: the docs
  # never claim it normalizes "castelooo" to "castelo", so the tokenizer's
  # own collapse stays regardless, and also covers the Deepgram and local
  # Whisper paths, which have no such option at all.
  defp no_verbatim?, do: System.get_env("ELEVEN_NO_VERBATIM") in ~w(1 true on)

  ## API

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  def send_audio(pid, bin), do: GenServer.cast(pid, {:audio, bin})

  ## Callbacks

  @impl true
  def init(parent) do
    case connect() do
      {:ok, conn, ref, ws} ->
        Logger.info("[elevenlabs] connected (commit=#{System.get_env("ELEVEN_COMMIT", "vad")})")

        {:ok,
         %{
           parent: parent,
           conn: conn,
           ref: ref,
           ws: ws,
           chunks_sent: 0,
           session_started: false
         }}

      {:error, reason} ->
        Logger.error("[stt] connect failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:audio, bin}, %{conn: conn, ref: ref, ws: ws} = state) do
    commit_mode = System.get_env("ELEVEN_COMMIT", "vad")

    base_msg = %{
      message_type: "input_audio_chunk",
      audio_base_64: Base.encode64(bin)
    }

    # With manual commit, commit each chunk so Eleven emits a transcript per chunk
    # With vad, leave it to the server
    msg =
      if commit_mode == "manual" do
        Map.put(base_msg, :commit, true)
      else
        base_msg
      end

    payload = Jason.encode!(msg)

    if rem(state.chunks_sent, 20) == 0 do
      Logger.debug(
        "[elevenlabs] sent #{state.chunks_sent} chunks total (each #{byte_size(bin)}B PCM)"
      )
    end

    case Mint.WebSocket.encode(ws, {:text, payload}) do
      {:ok, ws2, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn2} ->
            {:noreply, %{state | conn: conn2, ws: ws2, chunks_sent: state.chunks_sent + 1}}

          {:error, conn2, reason} ->
            {:stop, {:send_failed, reason}, %{state | conn: conn2}}
        end

      {:error, ws2, reason} ->
        {:stop, {:encode_failed, reason}, %{state | ws: ws2}}
    end
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        if responses != [],
          do: Logger.debug("[elevenlabs] stream got #{length(responses)} responses")

        state = %{state | conn: conn}
        state = Enum.reduce(responses, state, &handle_response/2)
        {:noreply, state}

      {:error, conn, reason, _responses} ->
        Logger.warning("[stt] stream error: #{inspect(reason)}")
        {:stop, reason, %{state | conn: conn}}

      :unknown ->
        Logger.debug("[elevenlabs] unknown stream message: #{inspect(message)}")
        {:noreply, state}
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, ws: ws} = state) do
    Logger.debug("[elevenlabs] data response: #{byte_size(data)}B")

    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws2, frames} ->
        Logger.debug("[elevenlabs] decoded #{length(frames)} frames")
        Enum.each(frames, &handle_frame(&1, state.parent))
        %{state | ws: ws2}

      {:error, ws2, reason} ->
        Logger.warning("[stt] decode failed: #{inspect(reason)}")
        %{state | ws: ws2}
    end
  end

  defp handle_response({:done, ref}, %{ref: ref} = state) do
    Logger.warning("[elevenlabs] connection done")
    send(state.parent, {:stt_error, :elevenlabs, :closed})
    state
  end

  defp handle_response(other, state) do
    Logger.debug("[elevenlabs] other response: #{inspect(other)}")
    state
  end

  defp handle_frame({:text, payload}, parent) do
    Logger.info("[elevenlabs] TEXT FRAME: #{payload}")

    case Jason.decode(payload) do
      {:ok, %{"message_type" => "partial_transcript", "text" => text}}
      when is_binary(text) and text != "" ->
        send(parent, {:transcript, :elevenlabs, text, false, System.system_time(:millisecond)})

      {:ok, %{"message_type" => "committed_transcript", "text" => text}}
      when is_binary(text) and text != "" ->
        send(parent, {:transcript, :elevenlabs, text, true, System.system_time(:millisecond)})

      {:ok, %{"message_type" => mt}} when mt in ["error", "auth_error", "quota_exceeded"] ->
        send(parent, {:stt_error, :elevenlabs, payload})

      _ ->
        :ok
    end
  end

  defp handle_frame({:close, code, reason}, parent) do
    Logger.warning("[elevenlabs] CLOSE FRAME: code=#{inspect(code)} reason=#{inspect(reason)}")
    send(parent, {:stt_error, :elevenlabs, {:closed_by_remote, code, reason}})
  end

  defp handle_frame({:binary, data}, _parent) do
    snippet = binary_part(data, 0, min(80, byte_size(data))) |> Base.encode16()
    Logger.info("[elevenlabs] BINARY FRAME: #{byte_size(data)}B (first 80B hex): #{snippet}")
  end

  defp handle_frame({:ping, data}, _parent) do
    Logger.info("[elevenlabs] PING (#{byte_size(data)}B)")
  end

  defp handle_frame({:pong, data}, _parent) do
    Logger.info("[elevenlabs] PONG (#{byte_size(data)}B)")
  end

  defp handle_frame(other, _parent) do
    Logger.warning("[elevenlabs] UNKNOWN FRAME: #{inspect(other)}")
  end

  ## Connection

  defp connect do
    cfg = Application.fetch_env!(:sinestesia, :config)
    key = Keyword.get(cfg, :elevenlabs_api_key)

    if is_nil(key) or key == "" do
      {:error, :no_api_key}
    else
      with {:ok, conn} <-
             Mint.HTTP.connect(:https, @host, @port,
               protocols: [:http1],
               transport_opts: [verify: :verify_none]
             ),
           {:ok, conn, ref} <-
             Mint.WebSocket.upgrade(:wss, conn, path(), [
               {"xi-api-key", key}
             ]),
           {:ok, conn, ws} <- await_upgrade(conn, ref) do
        {:ok, conn, ref, ws}
      end
    end
  end

  defp await_upgrade(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            with {:ok, status, headers} <- collect_upgrade(responses, ref, nil, []),
                 {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, status, headers) do
              {:ok, conn, ws}
            end

          {:error, conn, reason, _} ->
            {:error, conn, reason}
        end
    after
      5_000 -> {:error, :upgrade_timeout}
    end
  end

  defp collect_upgrade([], _ref, status, headers) when not is_nil(status),
    do: {:ok, status, headers}

  defp collect_upgrade([{:status, ref, s} | rest], ref, _status, headers),
    do: collect_upgrade(rest, ref, s, headers)

  defp collect_upgrade([{:headers, ref, h} | rest], ref, status, headers),
    do: collect_upgrade(rest, ref, status, headers ++ h)

  defp collect_upgrade([{:done, ref} | rest], ref, status, headers),
    do: collect_upgrade(rest, ref, status, headers)

  defp collect_upgrade([_ | rest], ref, status, headers),
    do: collect_upgrade(rest, ref, status, headers)

  defp collect_upgrade([], _ref, _status, _headers), do: {:error, :incomplete_upgrade}
end
