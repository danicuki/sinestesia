defmodule Sinestesia.PipelineStructureTest do
  @moduledoc """
  State-machine invariants for musical structure (Phase 2) that need no
  network: structure is derived on `set_lyrics`, position/section tracking is
  independent of SPECULATIVE_LOOKAHEAD, and MUSICAL_STRUCTURE off is fully
  inert (same "byte-for-byte unchanged" guarantee Phase 1 made for look-ahead).

  Director/image behavior (the section hint actually reaching a live LLM call)
  is verified via the replay harness, not here — this file only checks the
  state machine and the `structure` push.
  """
  use ExUnit.Case, async: false

  @song """
  verse line one
  verse line two

  chorus line one
  chorus line two

  verse three unique

  chorus line one
  chorus line two
  """

  setup do
    prev = %{
      stt: System.get_env("STT_PROVIDER"),
      look: System.get_env("SPECULATIVE_LOOKAHEAD"),
      struct: System.get_env("MUSICAL_STRUCTURE")
    }

    System.put_env("STT_PROVIDER", "replay")
    System.delete_env("SPECULATIVE_LOOKAHEAD")
    System.delete_env("MUSICAL_STRUCTURE")
    System.delete_env("REPLAY_FILE")

    {:ok, pid} = Sinestesia.Pipeline.start_link(self())

    on_exit(fn ->
      restore("STT_PROVIDER", prev.stt)
      restore("SPECULATIVE_LOOKAHEAD", prev.look)
      restore("MUSICAL_STRUCTURE", prev.struct)

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

  defp sing(pid, text), do: send(pid, {:transcript, :replay, text, true, 0})

  test "set_lyrics with raw text derives structure with a detected chorus", %{pid: pid} do
    Sinestesia.Pipeline.set_lyrics(pid, @song)
    state = :sys.get_state(pid)

    assert length(state.structure.sections) == 4
    choruses = Enum.filter(state.structure.sections, &(&1.label == :chorus))
    assert length(choruses) == 2
    assert Enum.map(choruses, & &1.occurrence) == [1, 2]
  end

  test "MUSICAL_STRUCTURE off: confirmed lines never move the position", %{pid: pid} do
    Sinestesia.Pipeline.set_lyrics(pid, @song)
    sing(pid, "verse line one")
    _ = :sys.get_state(pid)

    state = :sys.get_state(pid)
    assert state.script_cursor == -1
    assert state.current_section == nil
    refute_received {:push_json, %{type: "structure"}}
  end

  test "MUSICAL_STRUCTURE on (look-ahead off): position and section track, cursor advances", %{
    pid: pid
  } do
    System.put_env("MUSICAL_STRUCTURE", "on")
    Sinestesia.Pipeline.set_lyrics(pid, @song)

    sing(pid, "verse line one")
    _ = :sys.get_state(pid)
    state = :sys.get_state(pid)
    assert state.script_cursor == 0
    assert Enum.at(state.structure.sections, state.current_section).label == :verse
    # Speculation is never touched by structure-only tracking.
    assert state.speculation == nil

    sing(pid, "chorus line one")
    _ = :sys.get_state(pid)
    state = :sys.get_state(pid)
    assert state.script_cursor == 2
    section = Enum.at(state.structure.sections, state.current_section)
    assert section.label == :chorus
    assert section.occurrence == 1
  end

  test "MUSICAL_STRUCTURE on: entering a new section pushes a `structure` message", %{pid: pid} do
    System.put_env("MUSICAL_STRUCTURE", "on")
    Sinestesia.Pipeline.set_lyrics(pid, @song)

    sing(pid, "verse line one")

    assert_receive {:push_json, %{type: "structure", section: section}}, 1000
    assert section.label == "verse"
    assert section.occurrence == 1
    assert section.index == 0
  end

  test "MUSICAL_STRUCTURE on: the second chorus occurrence is reported correctly", %{pid: pid} do
    System.put_env("MUSICAL_STRUCTURE", "on")
    Sinestesia.Pipeline.set_lyrics(pid, @song)

    sing(pid, "verse line one")
    assert_receive {:push_json, %{type: "structure"}}, 1000

    sing(pid, "chorus line one")

    assert_receive {:push_json, %{type: "structure", section: %{label: "chorus", occurrence: 1}}},
                   1000

    sing(pid, "verse three unique")
    assert_receive {:push_json, %{type: "structure", section: %{label: "bridge"}}}, 1000

    sing(pid, "chorus line one")

    assert_receive {:push_json, %{type: "structure", section: %{label: "chorus", occurrence: 2}}},
                   1000
  end

  test "MUSICAL_STRUCTURE + SPECULATIVE_LOOKAHEAD together: position tracks via the look-ahead path too",
       %{pid: pid} do
    System.put_env("MUSICAL_STRUCTURE", "on")
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    # bootstrap_done?: true so set_lyrics doesn't ALSO spawn a real eager-
    # bootstrap Director call (a separate feature, its own test file) — this
    # test is only about structure/position tracking.
    :sys.replace_state(pid, fn state -> %{state | bootstrap_done?: true} end)
    Sinestesia.Pipeline.set_lyrics(pid, @song)

    sing(pid, "verse line one")
    assert_receive {:push_json, %{type: "structure", section: %{label: "verse"}}}, 1000

    state = :sys.get_state(pid)
    assert state.script_cursor == 0
    assert Enum.at(state.structure.sections, state.current_section).label == :verse
  end

  test "reset clears position but keeps the structure", %{pid: pid} do
    System.put_env("MUSICAL_STRUCTURE", "on")
    Sinestesia.Pipeline.set_lyrics(pid, @song)
    sing(pid, "verse line one")
    _ = :sys.get_state(pid)

    Sinestesia.Pipeline.reset_song(pid)
    state = :sys.get_state(pid)

    assert state.current_section == nil
    assert state.script_cursor == -1
    assert length(state.structure.sections) == 4
  end

  test "fast_features smooths into tempo_bpm and pushes it once a section is known", %{pid: pid} do
    System.put_env("MUSICAL_STRUCTURE", "on")
    Sinestesia.Pipeline.set_lyrics(pid, @song)

    sing(pid, "verse line one")
    assert_receive {:push_json, %{type: "structure", tempo_bpm: nil}}, 1000

    Sinestesia.Pipeline.fast_features(pid, %{"rms" => 0.2, "tempo_estimate" => 100})
    assert_receive {:push_json, %{type: "structure", tempo_bpm: 100}}, 1000

    state = :sys.get_state(pid)
    assert_in_delta state.tempo_bpm, 100.0, 0.01
  end

  test "an implausible tempo reading is ignored, not pushed as a change", %{pid: pid} do
    System.put_env("MUSICAL_STRUCTURE", "on")
    Sinestesia.Pipeline.set_lyrics(pid, @song)
    sing(pid, "verse line one")
    assert_receive {:push_json, %{type: "structure"}}, 1000

    Sinestesia.Pipeline.fast_features(pid, %{"rms" => 0.2, "tempo_estimate" => 9999})
    refute_receive {:push_json, %{type: "structure"}}, 300

    assert :sys.get_state(pid).tempo_bpm == nil
  end

  test "an off-script line does not move the position or crash", %{pid: pid} do
    System.put_env("MUSICAL_STRUCTURE", "on")
    Sinestesia.Pipeline.set_lyrics(pid, @song)

    sing(pid, "completely unrelated improvised words nowhere in the script")
    _ = :sys.get_state(pid)

    state = :sys.get_state(pid)
    assert state.script_cursor == -1
    assert state.current_section == nil
  end
end
