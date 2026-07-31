defmodule Sinestesia.ReplaySTT do
  @moduledoc """
  Fake STT provider that replays a recorded session — transcripts with their
  original timestamps — into the Pipeline, so the full Director → image chain
  can be exercised without anyone singing.

  Select with `STT_PROVIDER=replay` and point `REPLAY_FILE` at a session JSON
  (see `tests/sessions/`, generated from backend logs by
  `tools/log_to_session.py`):

      {
        "name": "aquarela-tarsila",
        "style": "Tarsila do Amaral style, ...",   // optional
        "events": [
          {"at_ms": 0,    "text": "Numa folha qualquer.", "final": false},
          {"at_ms": 4526, "text": "Numa folha qualquer eu desenho um sol amarelooo.", "final": true}
        ]
      }

  Playback starts as soon as the Pipeline starts (browser connect, or the
  `mix sinestesia.replay` headless task). A song `reset` restarts the session
  from the top — handy for iterating: tweak, click "nova música", watch again.

  `REPLAY_SPEED=2.0` compresses the gaps between events 2x. The Director's
  min-interval and the real model latencies still apply, so high speeds mainly
  reduce idle time rather than truly running the song faster.
  """
  use GenServer
  require Logger

  def start_link(parent) do
    case System.get_env("REPLAY_FILE") do
      nil -> {:error, :replay_file_not_set}
      file -> GenServer.start_link(__MODULE__, {parent, file})
    end
  end

  @doc "Audio is ignored in replay mode (the mic can stay on or off)."
  def send_audio(_pid, _bin), do: :ok

  @doc "Restart playback from the first event (wired to song reset)."
  def reset(pid), do: GenServer.cast(pid, :reset)

  @impl true
  def init({parent, file}) do
    speed =
      case Float.parse(System.get_env("REPLAY_SPEED", "1.0")) do
        {s, _} when s > 0 -> s
        _ -> 1.0
      end

    case load(file) do
      {:ok, session} ->
        Logger.info(
          "[replay] #{session.name}: #{length(session.events)} events over #{div(session.duration_ms, 1000)}s (speed #{speed}x)"
        )

        send(self(), :start)
        {:ok, %{parent: parent, session: session, speed: speed, started_at: nil, epoch: 0}}

      {:error, reason} ->
        Logger.error("[replay] failed to load #{file}: #{inspect(reason)}")
        {:stop, {:bad_replay_file, reason}}
    end
  end

  @impl true
  def handle_info(:start, state) do
    if state.session.style do
      send(state.parent, {:replay_style, state.session.style})
    end

    # A recorded session may carry the song's lyrics, so predictive look-ahead
    # (SPECULATIVE_LOOKAHEAD) can be exercised headlessly against a real session.
    if state.session.lyrics do
      send(state.parent, {:replay_lyrics, state.session.lyrics})
    end

    schedule(state, 0)
    {:noreply, %{state | started_at: now_ms()}}
  end

  # Fires from a previous run (before a reset) carry a stale epoch — drop them.
  def handle_info({:fire, epoch, _idx}, %{epoch: cur} = state) when epoch != cur,
    do: {:noreply, state}

  def handle_info({:fire, _epoch, idx}, state) do
    case Enum.at(state.session.events, idx) do
      nil ->
        {:noreply, state}

      ev ->
        send(state.parent, {:transcript, :replay, ev.text, ev.final, now_ms()})
        schedule(state, idx + 1)

        if idx == length(state.session.events) - 1 do
          elapsed = div(now_ms() - state.started_at, 1000)
          Logger.info("[replay] done — #{idx + 1} events replayed in #{elapsed}s")
          send(state.parent, {:replay_done, state.session.name})
        end

        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:reset, state) do
    Logger.info("[replay] reset — restarting #{state.session.name} from the top")
    send(self(), :start)
    {:noreply, %{state | epoch: state.epoch + 1}}
  end

  defp schedule(state, idx) do
    case Enum.at(state.session.events, idx) do
      nil ->
        :ok

      ev ->
        prev_at = if idx == 0, do: 0, else: Enum.at(state.session.events, idx - 1).at_ms
        delay = max(round((ev.at_ms - prev_at) / state.speed), 0)
        Process.send_after(self(), {:fire, state.epoch, idx}, delay)
    end
  end

  defp load(file) do
    with {:ok, raw} <- File.read(file),
         {:ok, json} <- Jason.decode(raw),
         %{"events" => events} when is_list(events) and events != [] <- json do
      parsed =
        events
        |> Enum.map(fn ev ->
          %{
            at_ms: Map.fetch!(ev, "at_ms"),
            text: Map.fetch!(ev, "text"),
            final: Map.get(ev, "final", false)
          }
        end)
        |> Enum.sort_by(& &1.at_ms)

      {:ok,
       %{
         name: Map.get(json, "name", Path.basename(file, ".json")),
         style: Map.get(json, "style"),
         lyrics: Map.get(json, "lyrics"),
         events: parsed,
         duration_ms: List.last(parsed).at_ms
       }}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_session, other}}
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
