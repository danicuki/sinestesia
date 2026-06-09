defmodule Sinestesia.LocalWhisperSTT do
  @moduledoc """
  Streaming STT client for the local Whisper sidecar (see `local-whisper/`).

  Connects to ws://127.0.0.1:8002/transcribe (overridable via env vars),
  sends 16 kHz Int16 LE PCM as binary frames, receives JSON transcripts of
  shape `{"type": "transcript", "text": "...", "is_final": bool}`.

  Forwards each transcript to the parent process as:
    {:transcript, :local_whisper, text, is_final, recv_ts}

  Identical message shape to ElevenSTT / Deepgram so the Pipeline treats
  it as just another provider.
  """
  use GenServer
  require Logger

  defp host, do: System.get_env("LOCAL_WHISPER_HOST", "127.0.0.1")
  defp port, do: System.get_env("LOCAL_WHISPER_PORT", "8002") |> String.to_integer()
  defp path, do: System.get_env("LOCAL_WHISPER_PATH", "/transcribe")

  ## API

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
  def send_audio(pid, bin), do: GenServer.cast(pid, {:audio, bin})
  def reset(pid), do: GenServer.cast(pid, :reset)

  ## Callbacks

  @impl true
  def init(parent) do
    case connect() do
      {:ok, conn, ref, ws} ->
        Logger.info("[local_whisper] connected to ws://#{host()}:#{port()}#{path()}")

        {:ok,
         %{
           parent: parent,
           conn: conn,
           ref: ref,
           ws: ws,
           chunks_sent: 0
         }}

      {:error, reason} ->
        Logger.error("[local_whisper] connect failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:audio, bin}, %{conn: conn, ref: ref, ws: ws} = state) do
    if rem(state.chunks_sent, 40) == 0 do
      Logger.debug("[local_whisper] sent #{state.chunks_sent} chunks total (#{byte_size(bin)}B each)")
    end

    case Mint.WebSocket.encode(ws, {:binary, bin}) do
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

  def handle_cast(:reset, %{conn: conn, ref: ref, ws: ws} = state) do
    payload = Jason.encode!(%{type: "reset"})

    case Mint.WebSocket.encode(ws, {:text, payload}) do
      {:ok, ws2, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn2} ->
            Logger.info("[local_whisper] sent reset")
            {:noreply, %{state | conn: conn2, ws: ws2}}

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
        state = %{state | conn: conn}
        state = Enum.reduce(responses, state, &handle_response/2)
        {:noreply, state}

      {:error, conn, reason, _responses} ->
        Logger.warning("[local_whisper] stream error: #{inspect(reason)}")
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
        Logger.warning("[local_whisper] decode failed: #{inspect(reason)}")
        %{state | ws: ws2}
    end
  end

  defp handle_response({:done, ref}, %{ref: ref} = state) do
    Logger.warning("[local_whisper] connection done")
    send(state.parent, {:stt_error, :local_whisper, :closed})
    state
  end

  defp handle_response(_other, state), do: state

  defp handle_frame({:text, payload}, parent) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "transcript", "text" => text, "is_final" => is_final}}
      when is_binary(text) and text != "" ->
        send(parent, {:transcript, :local_whisper, text, is_final, System.system_time(:millisecond)})

      {:ok, other} ->
        Logger.debug("[local_whisper] unknown message: #{inspect(other)}")

      {:error, _} ->
        Logger.debug("[local_whisper] non-JSON text frame: #{inspect(payload)}")
    end
  end

  defp handle_frame({:close, _code, _reason}, parent) do
    send(parent, {:stt_error, :local_whisper, :closed})
  end

  # NOTE: ping/pong handling is left unimplemented here — the local server is
  # configured with ping_interval=None, so we never expect a ping. If you ever
  # wire this client through a proxy that injects keepalive pings, swap to
  # handle :ping by encoding and sending back a :pong frame.
  defp handle_frame(_frame, _parent), do: :ok

  ## WebSocket connect (plain HTTP, since it's localhost)

  defp connect do
    case Mint.HTTP.connect(:http, host(), port(), protocols: [:http1]) do
      {:ok, conn} ->
        case Mint.WebSocket.upgrade(:ws, conn, path(), []) do
          {:ok, conn, ref} ->
            await_upgrade(conn, ref)

          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:error, {:upgrade, reason}}
        end

      {:error, reason} ->
        {:error, {:tcp, reason}}
    end
  end

  defp await_upgrade(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            handle_upgrade(conn, ref, responses)

          {:error, conn, reason, _} ->
            Mint.HTTP.close(conn)
            {:error, {:stream, reason}}
        end
    after
      5_000 ->
        Mint.HTTP.close(conn)
        {:error, :upgrade_timeout}
    end
  end

  defp handle_upgrade(conn, ref, responses) do
    status = Enum.find_value(responses, fn
      {:status, ^ref, code} -> code
      _ -> nil
    end)

    headers = Enum.find_value(responses, fn
      {:headers, ^ref, hdrs} -> hdrs
      _ -> nil
    end)

    cond do
      status && headers ->
        case Mint.WebSocket.new(conn, ref, status, headers) do
          {:ok, conn, ws} -> {:ok, conn, ref, ws}
          {:error, conn, reason} ->
            Mint.HTTP.close(conn)
            {:error, {:new, reason}}
        end

      true ->
        # Not all upgrade bits arrived yet; keep waiting.
        await_upgrade(conn, ref)
    end
  end
end
