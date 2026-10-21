defmodule Sinestesia.Deepgram do
  @moduledoc """
  Streaming STT client for Deepgram via Mint.WebSocket.

  Two model families, picked by `DEEPGRAM_MODEL`, behind one interface:

    * `nova-3` (default) — `/v1/listen`, `is_final` segments closed by
      endpointing. `DEEPGRAM_LANGUAGE=multi` (the default) is Nova-3
      Multilingual: auto-detects and code-switches across en/es/fr/de/hi/ru/
      pt/ja/it/nl; a code (`pt-BR`, `it`) pins one language.
    * `flux-general-multi` / `flux-general-en` — `/v2/listen`, Deepgram's
      turn-based model. It reports `TurnInfo` events; `EndOfTurn` is the final,
      every other event's running transcript is a partial. A language code in
      `DEEPGRAM_LANGUAGE` becomes a `language_hint`; `multi` means no hint.

  Binary frames of 16-bit LE PCM 16kHz mono are sent directly (no JSON wrapping).
  Transcripts are forwarded to the parent process as:
    {:transcript, :deepgram, text, is_final, received_at_ms}
  """
  use GenServer
  require Logger

  @host "api.deepgram.com"
  @port 443

  defp model, do: System.get_env("DEEPGRAM_MODEL", "nova-3")
  defp language, do: System.get_env("DEEPGRAM_LANGUAGE", "multi")
  defp flux?, do: String.starts_with?(model(), "flux")

  @doc "Model and language as they will be requested — for the boot banner."
  def describe do
    "#{model()} · #{if language() in ["", "multi"], do: "auto", else: language()}"
  end

  defp path do
    if flux?() do
      hint = if language() in ["", "multi"], do: "", else: "&language_hint=#{language()}"
      "/v2/listen?model=#{model()}&encoding=linear16&sample_rate=16000" <> hint
    else
      "/v1/listen?model=#{model()}&language=#{language()}&encoding=linear16&sample_rate=16000&channels=1&interim_results=true&endpointing=300&punctuate=true"
    end
  end

  ## API

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  def send_audio(pid, bin), do: GenServer.cast(pid, {:audio, bin})

  ## Callbacks

  @impl true
  def init(parent) do
    case connect() do
      {:ok, conn, ref, ws} ->
        Logger.info("[deepgram] connected (model=#{model()}, language=#{language()})")
        {:ok, %{parent: parent, conn: conn, ref: ref, ws: ws}}

      {:error, reason} ->
        Logger.error("[deepgram] connect failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:audio, bin}, %{conn: conn, ref: ref, ws: ws} = state) do
    case Mint.WebSocket.encode(ws, {:binary, bin}) do
      {:ok, ws2, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn2} -> {:noreply, %{state | conn: conn2, ws: ws2}}
          {:error, conn2, reason} -> {:stop, {:send_failed, reason}, %{state | conn: conn2}}
        end

      {:error, ws2, reason} ->
        {:stop, {:encode_failed, reason}, %{state | ws: ws2}}
    end
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        state = Enum.reduce(responses, state, &handle_response/2)
        {:noreply, state}

      {:error, conn, reason, _responses} ->
        Logger.warning("[deepgram] stream error: #{inspect(reason)}")
        {:stop, reason, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, ws: ws} = state) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws2, frames} ->
        Enum.each(frames, &handle_frame(&1, state.parent))
        %{state | ws: ws2}

      {:error, ws2, reason} ->
        Logger.warning("[deepgram] decode failed: #{inspect(reason)}")
        %{state | ws: ws2}
    end
  end

  defp handle_response({:done, ref}, %{ref: ref} = state) do
    Logger.warning("[deepgram] connection done")
    send(state.parent, {:stt_error, :deepgram, :closed})
    state
  end

  defp handle_response(_other, state), do: state

  defp handle_frame({:text, payload}, parent) do
    case Jason.decode(payload) do
      {:ok, %{"channel" => %{"alternatives" => [%{"transcript" => text} | _]}} = msg}
      when is_binary(text) and text != "" ->
        is_final = Map.get(msg, "is_final", false)
        send(parent, {:transcript, :deepgram, text, is_final, System.system_time(:millisecond)})

      # Flux: the transcript is cumulative within a turn, so each event
      # REPLACES the partial — the same contract as the other providers.
      {:ok, %{"type" => "TurnInfo", "event" => event, "transcript" => text}}
      when is_binary(text) and text != "" ->
        is_final = event == "EndOfTurn"
        send(parent, {:transcript, :deepgram, text, is_final, System.system_time(:millisecond)})

      {:ok, %{"type" => "Error"} = err} ->
        send(parent, {:stt_error, :deepgram, err})

      _ ->
        :ok
    end
  end

  defp handle_frame({:close, _code, _reason}, parent) do
    send(parent, {:stt_error, :deepgram, :closed_by_remote})
  end

  defp handle_frame(_frame, _parent), do: :ok

  ## Connection

  defp connect do
    cfg = Application.fetch_env!(:sinestesia, :config)
    key = Keyword.get(cfg, :deepgram_api_key)

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
               {"authorization", "Token " <> key}
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
