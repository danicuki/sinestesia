defmodule Sinestesia.AudioSocket do
  @moduledoc "WebSock handler: browser <-> backend. PCM in, transcripts + image URLs out."
  @behaviour WebSock
  require Logger

  @impl true
  def init(_arg) do
    case Sinestesia.Pipeline.start_link(self()) do
      {:ok, pid} ->
        Logger.info("[ws] connected, pipeline=#{inspect(pid)}")
        {:ok, %{pipeline: pid}}

      {:error, {:already_started, pid}} ->
        # Race: the previous Pipeline didn't release the Registry slot in time.
        # Adopt the existing one rather than crashing the connection.
        Logger.warning("[ws] adopting existing pipeline=#{inspect(pid)}")
        {:ok, %{pipeline: pid}}

      {:error, reason} ->
        Logger.error("[ws] pipeline start failed: #{inspect(reason)}")
        # Returning {:ok, ...} so Bandit doesn't crash the whole connection;
        # we just won't have a pipeline. Pipe operations become no-ops.
        {:ok, %{pipeline: nil}}
    end
  end

  @impl true
  def handle_in({_payload, [opcode: :binary]}, %{pipeline: nil} = state), do: {:ok, state}

  def handle_in({payload, [opcode: :binary]}, %{pipeline: pid} = state) do
    Sinestesia.Pipeline.audio_chunk(pid, payload)
    {:ok, state}
  end

  def handle_in({payload, [opcode: :text]}, %{pipeline: pid} = state) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "ping"}} ->
        {:reply, :ok, {:text, Jason.encode!(%{type: "pong"})}, state}

      {:ok, %{"type" => "expressive", "features" => features}} when not is_nil(pid) ->
        Sinestesia.Pipeline.expressive(pid, features)
        {:ok, state}

      {:ok, %{"type" => "fast_features"} = msg} when not is_nil(pid) ->
        Sinestesia.Pipeline.fast_features(pid, Map.drop(msg, ["type"]))
        {:ok, state}

      {:ok, %{"type" => "style", "style" => style}} when not is_nil(pid) ->
        Sinestesia.Pipeline.set_style(pid, style)
        {:ok, state}

      {:ok, %{"type" => "reset"}} when not is_nil(pid) ->
        Sinestesia.Pipeline.reset_song(pid)
        {:ok, state}

      {:ok, other} ->
        Logger.debug("[ws] unknown text msg: #{inspect(other)}")
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:push_json, msg}, state) do
    {:push, {:text, Jason.encode!(msg)}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(reason, %{pipeline: pid}) do
    Logger.info("[ws] disconnect (#{inspect(reason)})")
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :normal)
    :ok
  end
end
