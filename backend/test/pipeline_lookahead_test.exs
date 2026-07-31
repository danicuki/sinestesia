defmodule Sinestesia.PipelineLookaheadTest do
  @moduledoc """
  State-machine invariants for predictive look-ahead that need no network:
  loading/clearing lyrics, and the guarantee that with SPECULATIVE_LOOKAHEAD
  off the pipeline behaves exactly as before (no speculation is ever created).

  The full speculative render path (Director + image) is exercised end-to-end by
  the replay harness (see the Phase 1 verification), not here.
  """
  use ExUnit.Case, async: false

  setup do
    # No STT provider (replay selected but no REPLAY_FILE) → no sockets, no
    # network; and look-ahead off by default for the regression checks.
    prev = %{
      stt: System.get_env("STT_PROVIDER"),
      look: System.get_env("SPECULATIVE_LOOKAHEAD")
    }

    System.put_env("STT_PROVIDER", "replay")
    System.delete_env("SPECULATIVE_LOOKAHEAD")
    System.delete_env("REPLAY_FILE")

    {:ok, pid} = Sinestesia.Pipeline.start_link(self())

    on_exit(fn ->
      restore("STT_PROVIDER", prev.stt)
      restore("SPECULATIVE_LOOKAHEAD", prev.look)

      # The pipeline treats its socket (this test process) as its lifeline, so it
      # may already have stopped itself when the test ended — tolerate the race.
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end)

    %{pid: pid}
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, val), do: System.put_env(key, val)

  test "set_lyrics loads a script and marks it active", %{pid: pid} do
    Sinestesia.Pipeline.set_lyrics(pid, ["line one", "line two", "line three"])
    state = :sys.get_state(pid)

    assert state.script == ["line one", "line two", "line three"]
    assert state.script_active? == true
    assert state.script_cursor == -1
    assert state.speculation == nil
  end

  test "set_lyrics accepts a newline blob and drops blank lines", %{pid: pid} do
    Sinestesia.Pipeline.set_lyrics(pid, "  a  \n\n b \n")
    assert %{script: ["a", "b"], script_active?: true} = :sys.get_state(pid)
  end

  test "an empty payload clears the script", %{pid: pid} do
    Sinestesia.Pipeline.set_lyrics(pid, ["something"])
    assert :sys.get_state(pid).script_active? == true

    Sinestesia.Pipeline.set_lyrics(pid, [])
    state = :sys.get_state(pid)
    assert state.script == []
    assert state.script_active? == false
  end

  test "reset keeps the loaded lyrics but re-acquires the position", %{pid: pid} do
    Sinestesia.Pipeline.set_lyrics(pid, ["one", "two"])
    Sinestesia.Pipeline.reset_song(pid)
    state = :sys.get_state(pid)

    # Rehearsing the same song is common, so the script survives a reset…
    assert state.script == ["one", "two"]
    assert state.script_active? == true
    # …but the position and any look-ahead do not.
    assert state.script_cursor == -1
    assert state.speculation == nil
  end

  test "with look-ahead OFF, confirmed lyrics never create a speculation", %{pid: pid} do
    Sinestesia.Pipeline.set_lyrics(pid, ["numa folha qualquer", "e com cinco ou seis retas"])

    # Feed a confirmed final that would match line 0. Flag is off, so the
    # follower must not run and no speculation slot is ever populated.
    send(pid, {:transcript, :replay, "numa folha qualquer", true, 0})
    _ = :sys.get_state(pid)

    state = :sys.get_state(pid)
    assert state.speculation == nil
    # Cursor is untouched too — the whole look-ahead path is inert when off.
    assert state.script_cursor == -1
  end
end
