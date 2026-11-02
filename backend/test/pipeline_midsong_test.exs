defmodule Sinestesia.PipelineMidsongTest do
  @moduledoc """
  Look-ahead when the song becomes known MID-performance — auto-identified
  from its opening, or lyrics loaded by hand after the first lines — and the
  one invariant both depend on: the chain can restart from any confirmed
  line, not only from a scene boundary.

  Found live (2026-11-02, HANDOFF #53): on an auto-identified song the stage
  stayed black while an eager render of the already-sung opening was held,
  and after it finally revealed, look-ahead stalled whenever the cursor sat
  inside a 2-3 line scene — `chunk_after/2` only found scenes STARTING at the
  next line. Hermetic: every render completion is injected as the message a
  real Task would send.
  """
  use ExUnit.Case, async: false

  @script [
    "Numa folha qualquer eu desenho um sol amarelo",
    "E com cinco ou seis retas é fácil fazer um castelo",
    "Corro o lápis em torno da mão e me dou uma luva",
    "E se faço chover com dois riscos tenho um guarda-chuva",
    "Se um pinguinho de tinta cai num pedacinho azul do papel",
    "Num instante imagino uma linda gaivota a voar no céu"
  ]

  setup do
    prev = %{stt: System.get_env("STT_PROVIDER"), look: System.get_env("SPECULATIVE_LOOKAHEAD")}
    System.put_env("STT_PROVIDER", "replay")
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    System.delete_env("REPLAY_FILE")

    {:ok, pid} = Sinestesia.Pipeline.start_link(self())

    on_exit(fn ->
      restore("STT_PROVIDER", prev.stt)
      restore("SPECULATIVE_LOOKAHEAD", prev.look)

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

  # set_lyrics/2 spawns a real LyricsChunker Task; bumping chunk_generation
  # makes its (fast, keyless) answer stale so it can't land mid-test.
  defp load_script(pid) do
    Sinestesia.Pipeline.set_lyrics(pid, @script)
    :sys.replace_state(pid, fn s -> %{s | chunk_generation: s.chunk_generation + 1} end)
  end

  defp timings do
    %{
      stt_ms: 100,
      stt_provider: "replay",
      director_ms: 500,
      director_queue_ms: 0,
      image_started_at: System.system_time(:millisecond) - 200,
      image_call_ms: 200,
      lyric: "x",
      verification: nil
    }
  end

  # Two-line scenes, the shape Sinestesia.LyricsChunker produces.
  defp scenes do
    for {start, stop} <- [{0, 1}, {2, 3}, {4, 5}] do
      %{start_line: start, end_line: stop, text: Enum.join(Enum.slice(@script, start..stop), " ")}
    end
  end

  describe "chunk_after/2: the chain restarts from any confirmed line" do
    # A frame is on the canvas, the cursor is at `cursor`, and a reactive frame
    # lands — the handler calls maybe_speculate/1. Which scene gets rendered?
    defp land_reactive_frame_with_cursor_at(pid, cursor) do
      :sys.replace_state(pid, fn s ->
        %{s | bootstrap_done?: true, last_image_url: "https://example.test/0.jpg"}
      end)

      load_script(pid)

      :sys.replace_state(pid, fn s ->
        %{s | chunks: scenes(), script_cursor: cursor, speculation: nil}
      end)

      sid = :sys.get_state(pid).session_id
      send(pid, {:image_done, {:ok, "https://example.test/1.jpg", [], "prompt"}, timings(), sid})
      :sys.get_state(pid)
    end

    test "cursor on a scene boundary: the next scene", %{pid: pid} do
      assert %{index: 3} = land_reactive_frame_with_cursor_at(pid, 1).speculation
    end

    test "cursor mid-scene (line 0 of scene 0-1): the scene being sung, ending at line 1",
         %{pid: pid} do
      assert %{index: 1} = land_reactive_frame_with_cursor_at(pid, 0).speculation
    end

    test "cursor mid-scene (line 2 of scene 2-3): the scene ending at line 3", %{pid: pid} do
      assert %{index: 3} = land_reactive_frame_with_cursor_at(pid, 2).speculation
    end

    test "cursor on the last line: nothing left to look ahead to", %{pid: pid} do
      assert land_reactive_frame_with_cursor_at(pid, 5).speculation == nil
    end
  end

  describe "lyrics loaded while the singer is already into the song" do
    test "no eager opening is rendered and the cursor catches up to what was sung",
         %{pid: pid} do
      sing(pid, "Numa folha qualquer eu desenho um sol amarelo")
      sing(pid, "E com cinco ou seis retas é fácil fazer um castelo")

      load_script(pid)
      state = :sys.get_state(pid)

      assert state.script_active?
      assert state.bootstrap_speculation == nil
      assert state.script_cursor == 1
      # Nothing has been shown yet — the reactive path still owns the first frame.
      refute state.bootstrap_done?
    end

    test "sound-check chatter before the song does not count as singing it", %{pid: pid} do
      sing(pid, "um dois três testando som")

      load_script(pid)
      state = :sys.get_state(pid)

      # The eager opening is spawned exactly as for a silent load. (Its real
      # Director Task fails fast in this keyless env and may already have
      # discarded it by the time we look, so assert on the cursor, which only
      # the skip clause touches.)
      assert state.script_cursor == -1
    end
  end
end
