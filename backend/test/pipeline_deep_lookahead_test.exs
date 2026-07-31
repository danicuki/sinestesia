defmodule Sinestesia.PipelineDeepLookaheadTest do
  @moduledoc """
  State-machine invariants for deep look-ahead (Phase 3, LOOKAHEAD_DEPTH > 1):
  the background prerender chain builds correctly, respects the depth cap,
  promotes cleanly into the (already-tested) speculation slot on confirmation,
  and LOOKAHEAD_DEPTH=1 (default) never activates any of it — same guarantee
  Phase 1/2 made for their own flags.

  No network: every Director/image "completion" is injected directly as the
  message a real Task would have sent, exactly like the Phase 1/2 hermetic
  tests already do — this tests the state machine, not the LLM/image provider.
  """
  use ExUnit.Case, async: false

  @script ["line one", "line two", "line three", "line four", "line five"]

  setup do
    prev = %{
      stt: System.get_env("STT_PROVIDER"),
      look: System.get_env("SPECULATIVE_LOOKAHEAD"),
      depth: System.get_env("LOOKAHEAD_DEPTH")
    }

    System.put_env("STT_PROVIDER", "replay")
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    System.delete_env("REPLAY_FILE")
    System.delete_env("LOOKAHEAD_DEPTH")

    {:ok, pid} = Sinestesia.Pipeline.start_link(self())

    on_exit(fn ->
      restore("STT_PROVIDER", prev.stt)
      restore("SPECULATIVE_LOOKAHEAD", prev.look)
      restore("LOOKAHEAD_DEPTH", prev.depth)

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

  defp now_ms, do: System.system_time(:millisecond)

  defp base_timings do
    %{
      stt_ms: 100,
      stt_provider: "replay",
      director_ms: 500,
      director_queue_ms: 0,
      image_started_at: now_ms() - 200,
      image_call_ms: 200,
      lyric: "test line",
      verification: nil
    }
  end

  # Simulate the bootstrap frame having already landed, so the speculation
  # machinery's gates (bootstrap_done?, last_image_url) are satisfied.
  defp seed_bootstrap(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | bootstrap_done?: true, last_image_url: "https://example.test/bootstrap.jpg"}
    end)
  end

  # A finished, held (not-yet-revealed) frame in the shape reveal_speculation/1
  # and the cache both expect. Seeding this directly via :sys.replace_state —
  # rather than land_spec_director/land_spec_image, land_prerender_director/
  # land_prerender_image — is deliberate: those helpers' handlers spawn a REAL
  # image-generation Task as a side effect (that's the actual production
  # code path — see pipeline_bootstrap_test.exs's moduledoc for the full
  # explanation), and a test that ALSO seeds its own synthetic completion for
  # the same slot races that real Task. Several tests below used to chain
  # land_spec_director -> land_spec_image -> land_prerender_director ->
  # land_prerender_image back-to-back with no assertion in between — exactly
  # the risky pattern the moduledoc already warned about for THIS file's
  # very first two tests, just not yet applied here. Found live
  # (2026-07-31): adding a second always-on background Task
  # (Sinestesia.LyricsChunker, fired by every set_lyrics/2 call once
  # SPECULATIVE_LOOKAHEAD is on) measurably raised how often this pre-existing
  # race actually manifested, from roughly 1 run in 20 to roughly 1 in 3-5.
  defp seeded_frame(index, url) do
    %{
      index: index,
      line: Enum.at(@script, index),
      status: :ready,
      confirmed: false,
      pid: nil,
      new_conv: nil,
      step: nil,
      state_delta: nil,
      frame_msg: %{type: "image", url: url},
      frame_url: url,
      frame_route: nil,
      receipt: nil
    }
  end

  # set_lyrics/2 always spawns a REAL Sinestesia.LyricsChunker Task now (this
  # test env has no API keys, so it resolves fast with {:error, :no_key}, but
  # still asynchronously). Bumping chunk_generation right after makes that
  # result permanently stale, so it can never land mid-test and interleave
  # with this file's OWN synthetic spec/prerender messages — the same class
  # of real-Task race pipeline_bootstrap_test.exs's moduledoc already warns
  # about, just for a new async source this file didn't have to guard
  # against before.
  defp load_script(pid, script \\ @script) do
    Sinestesia.Pipeline.set_lyrics(pid, script)

    :sys.replace_state(pid, fn state ->
      %{state | chunk_generation: state.chunk_generation + 1}
    end)
  end

  defp land_bootstrap_image(pid) do
    send(
      pid,
      {:image_done, {:ok, "https://example.test/0.jpg", [], "prompt 0"}, base_timings(), 0}
    )
  end

  defp land_spec_director(pid, sid, index, conversation) do
    send(
      pid,
      {:spec_director_done, {:ok, "raw #{index}", conversation}, now_ms(), 10,
       %{provider: "test", model: "test"}, sid, index}
    )
  end

  defp land_spec_image(pid, sid, index, url) do
    send(
      pid,
      {:spec_image_done, {:ok, url, [], "prompt #{index}"}, base_timings(), sid, index}
    )
  end

  defp land_prerender_director(pid, sid, index, conversation, seed_url, seed_delta) do
    send(
      pid,
      {:prerender_director_done, {:ok, "raw #{index}", conversation}, now_ms(), 10,
       %{provider: "test", model: "test"}, sid, index, seed_url, seed_delta}
    )
  end

  defp land_prerender_image(pid, sid, index, url) do
    send(
      pid,
      {:prerender_image_done, {:ok, url, [], "prompt #{index}"}, base_timings(), sid, index}
    )
  end

  defp sing(pid, text), do: send(pid, {:transcript, :replay, text, true, 0})

  # A held eager bootstrap whose image has JUST landed: nothing revealed,
  # nothing sung, bootstrap_done? still false. Seeded at :image status so the
  # real {:bootstrap_spec_image_done, ...} handler is what moves it to :ready.
  defp seed_pending_bootstrap(pid) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | script: @script,
          script_active?: true,
          chunks: Sinestesia.LyricsChunker.fallback(@script),
          bootstrap_generation: state.bootstrap_generation + 1,
          chunk_generation: state.chunk_generation + 1,
          bootstrap_speculation: %{
            status: :image,
            confirmed: false,
            pid: nil,
            new_conv: nil,
            step: nil,
            state_delta: nil,
            frame_msg: nil,
            frame_url: nil,
            frame_route: nil,
            receipt: nil,
            text: "line one",
            target_index: 0
          }
      }
    end)

    :sys.get_state(pid)
  end

  test "the buffer is primed during the silence BEFORE the first note, not after the first reveal",
       %{pid: pid} do
    # The founder's own description of the happy path: load the lyrics, and by
    # the time the first line is sung there should already be a few frames
    # waiting. Before HANDOFF #43 the whole deep chain was gated behind
    # bootstrap_done?, which only flips on the first REVEAL — so a song loaded
    # 20 seconds before the downbeat still had exactly one frame ready, and the
    # buffer was only built while the singer was already performing.
    System.put_env("LOOKAHEAD_DEPTH", "3")
    state = seed_pending_bootstrap(pid)

    send(
      pid,
      {:bootstrap_spec_image_done, {:ok, "https://example.test/opening.jpg", [], "opening prompt"},
       base_timings(), state.session_id, state.bootstrap_generation}
    )

    state = :sys.get_state(pid)

    # Still held — nothing has been sung, so nothing is on screen yet.
    assert %{status: :ready} = state.bootstrap_speculation
    refute state.bootstrap_done?

    # ...but the chain is already running ahead of the performance.
    assert %{index: 1} = state.prerender
  end

  test "the primed buffer survives the first confirmed line instead of being wiped and re-rendered",
       %{pid: pid} do
    # Live regression (HANDOFF #44): the opening line confirmed while the eager
    # bootstrap was still held took best_candidate/4's :none branch — the
    # speculation slot is empty by design in that state, and cached frames for
    # LATER scenes can't fall inside the jump's range — and :none discarded the
    # whole prerender cache. The log showed line 3 cached at 18:23:15 and then
    # re-rendered from scratch at 18:23:32, wasting the head start.
    System.put_env("LOOKAHEAD_DEPTH", "3")
    state = seed_pending_bootstrap(pid)

    :sys.replace_state(pid, fn s ->
      %{s | prerendered: %{1 => seeded_frame(1, "https://example.test/cached1.jpg")}}
    end)

    send(
      pid,
      {:bootstrap_spec_image_done, {:ok, "https://example.test/opening.jpg", [], "opening prompt"},
       base_timings(), state.session_id, state.bootstrap_generation}
    )

    # The opening line lands while the bootstrap is still holding its frame.
    sing(pid, "line one")

    state = :sys.get_state(pid)

    # The bootstrap reveals on this line, and speculate_next/1 promotes the
    # cached frame straight into the active slot — status :ready, no render.
    # Had the cache been wiped, this would be a freshly spawned :director.
    assert %{index: 1, status: :ready, frame_url: "https://example.test/cached1.jpg"} =
             state.speculation
  end

  test "a held bootstrap counts toward LOOKAHEAD_DEPTH, so the buffer is depth frames, not depth+1",
       %{pid: pid} do
    System.put_env("LOOKAHEAD_DEPTH", "2")
    state = seed_pending_bootstrap(pid)

    send(
      pid,
      {:bootstrap_spec_image_done, {:ok, "https://example.test/opening.jpg", [], "opening prompt"},
       base_timings(), state.session_id, state.bootstrap_generation}
    )

    # Opening frame + one prerender in flight = 2. The chain must now stop.
    state = :sys.get_state(pid)
    assert %{index: 1} = state.prerender

    :sys.replace_state(pid, fn s ->
      %{s | prerender: nil, prerendered: Map.put(s.prerendered, 1, seeded_frame(1, "u1"))}
    end)

    send(pid, {:prerender_image_done, {:ok, "u1", [], "p1"}, base_timings(), state.session_id, 1})

    assert :sys.get_state(pid).prerender == nil
  end

  test "LOOKAHEAD_DEPTH=1 (default): the bootstrap reveal arms one speculation, never a prerender",
       %{pid: pid} do
    # seed_bootstrap BEFORE set_lyrics: bootstrap_done? must already be true
    # when lyrics load, or maybe_speculate_bootstrap/1 would ALSO spawn a real
    # eager-bootstrap Director call (a separate feature, its own test file) and
    # race with this test's synthetic speculation/prerender messages.
    seed_bootstrap(pid)
    load_script(pid)
    land_bootstrap_image(pid)

    state = :sys.get_state(pid)
    assert %{index: 0, status: :director} = state.speculation
    assert state.prerender == nil
    assert state.prerendered == %{}

    # Even once that speculation becomes ready, depth=1 must not deepen it.
    sid = state.session_id
    land_spec_director(pid, sid, 0, state.director_conversation)
    land_spec_image(pid, sid, 0, "https://example.test/1.jpg")

    state = :sys.get_state(pid)
    assert %{index: 0, status: :ready} = state.speculation
    assert state.prerender == nil
    assert state.prerendered == %{}
  end

  test "LOOKAHEAD_DEPTH=3: the chain deepens automatically as each render lands, up to the cap",
       %{pid: pid} do
    System.put_env("LOOKAHEAD_DEPTH", "3")
    # seed_bootstrap BEFORE set_lyrics: bootstrap_done? must already be true
    # when lyrics load, or maybe_speculate_bootstrap/1 would ALSO spawn a real
    # eager-bootstrap Director call (a separate feature, its own test file) and
    # race with this test's synthetic speculation/prerender messages.
    seed_bootstrap(pid)
    load_script(pid)
    land_bootstrap_image(pid)

    state = :sys.get_state(pid)
    sid = state.session_id
    assert %{index: 0, status: :director} = state.speculation
    # Can't deepen yet — the active speculation has no image to seed from.
    assert state.prerender == nil

    land_spec_director(pid, sid, 0, state.director_conversation)
    land_spec_image(pid, sid, 0, "https://example.test/1.jpg")

    state = :sys.get_state(pid)

    assert %{index: 0, status: :ready, frame_url: "https://example.test/1.jpg"} =
             state.speculation

    # Speculation just became a valid frontier — a prerender for line 1 should
    # have started automatically.
    assert %{index: 1, status: :director} = state.prerender

    land_prerender_director(
      pid,
      sid,
      1,
      state.speculation.new_conv,
      state.speculation.frame_url,
      %{}
    )

    state = :sys.get_state(pid)
    assert %{index: 1, status: :image} = state.prerender

    land_prerender_image(pid, sid, 1, "https://example.test/2.jpg")
    state = :sys.get_state(pid)
    # Landed in the cache, NOT revealed — and immediately tried to deepen again
    # (extent 1 speculation + 1 cached = 2, still under depth 3).
    assert map_size(state.prerendered) == 1
    assert %{status: :ready, frame_url: "https://example.test/2.jpg"} = state.prerendered[1]
    assert %{index: 2, status: :director} = state.prerender

    land_prerender_director(
      pid,
      sid,
      2,
      state.prerendered[1].new_conv,
      state.prerendered[1].frame_url,
      %{}
    )

    land_prerender_image(pid, sid, 2, "https://example.test/3.jpg")

    state = :sys.get_state(pid)
    # extent now 1 (speculation) + 2 (prerendered 1,2) = 3 = depth — must stop.
    assert map_size(state.prerendered) == 2
    assert state.prerender == nil
  end

  test "LOOKAHEAD_DEPTH=3: confirming a line promotes the cache instead of re-rendering",
       %{pid: pid} do
    System.put_env("LOOKAHEAD_DEPTH", "3")
    seed_bootstrap(pid)
    load_script(pid)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | speculation: seeded_frame(0, "https://example.test/1.jpg"),
          prerendered: %{1 => seeded_frame(1, "https://example.test/2.jpg")}
      }
    end)

    state = :sys.get_state(pid)
    assert map_size(state.prerendered) == 1
    assert state.speculation.index == 0

    # Confirm line 0 was sung -> reveal_speculation adopts it, then
    # speculate_next(1) should find line 1 ALREADY in the cache and promote it
    # instantly rather than spawning a fresh render.
    sing(pid, "line one")

    state = :sys.get_state(pid)
    assert state.script_cursor == 0

    assert %{index: 1, status: :ready, frame_url: "https://example.test/2.jpg"} =
             state.speculation

    # The promoted entry is gone from the cache.
    refute Map.has_key?(state.prerendered, 1)
  end

  test "an utterance that jumps past the held speculation reveals a CACHED further line instead of discarding it",
       %{pid: pid} do
    # Seeded directly via :sys.replace_state (not the land_spec_* helpers):
    # this test only cares about the CONFIRMATION-time reconciliation logic,
    # not how the speculation/cache got built — driving it through real
    # director/image spawns would race a real background Task for no benefit
    # here (see the moduledoc note on this in pipeline_bootstrap_test.exs).
    System.put_env("LOOKAHEAD_DEPTH", "3")
    seed_bootstrap(pid)
    load_script(pid)

    frame = fn index, url ->
      %{
        index: index,
        line: Enum.at(@script, index),
        status: :ready,
        confirmed: false,
        pid: nil,
        new_conv: nil,
        step: nil,
        state_delta: nil,
        frame_msg: %{type: "image", url: url},
        frame_url: url,
        frame_route: nil,
        receipt: nil
      }
    end

    :sys.replace_state(pid, fn state ->
      %{
        state
        | script_cursor: 0,
          last_image_url: "https://example.test/1.jpg",
          speculation: frame.(1, "https://example.test/2.jpg"),
          prerendered: %{2 => frame.(2, "https://example.test/3.jpg")}
      }
    end)

    # Caught live (2026-07-31): STT's own VAD segmentation bundled TWO short
    # lines into one utterance, so the confirmed text matches "line three"
    # (index 2) directly — skipping right past the still-held, already-
    # rendered "line two" (index 1). Before this fix, ANY non-exact match
    # discarded the held speculation outright and fell back to a slower
    # reactive render — throwing away a perfectly good, already-rendered
    # frame for content that was, in fact, already covered by the jump.
    sing(pid, "line three")

    state = :sys.get_state(pid)
    assert state.script_cursor == 2
    # The CACHED line 2 frame was revealed — not discarded, not re-rendered.
    assert state.last_image_url == "https://example.test/3.jpg"
    refute Map.has_key?(state.prerendered, 2)
  end

  test "off-script singing discards the speculation AND the whole prerender chain",
       %{pid: pid} do
    System.put_env("LOOKAHEAD_DEPTH", "3")
    seed_bootstrap(pid)
    load_script(pid)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | speculation: seeded_frame(0, "https://example.test/1.jpg"),
          prerendered: %{1 => seeded_frame(1, "https://example.test/2.jpg")}
      }
    end)

    assert map_size(:sys.get_state(pid).prerendered) == 1

    sing(pid, "completely unrelated improvised words nowhere in the script")

    state = :sys.get_state(pid)
    assert state.speculation == nil
    assert state.prerender == nil
    assert state.prerendered == %{}
    assert state.script_cursor == -1
  end

  test "confirming a line the prerender chain is STILL rendering waits instead of duplicating it",
       %{pid: pid} do
    System.put_env("LOOKAHEAD_DEPTH", "3")
    seed_bootstrap(pid)
    load_script(pid)

    # Seeds directly to the precondition the ORIGINAL flow (spec_director ->
    # spec_image -> auto-deepen) would have reached: line 0 ready, held; line
    # 1's prerender already in flight (:director, no pid — no real Task
    # backing it, since this test's subject is the CONFIRMATION race, not how
    # the chain got here).
    :sys.replace_state(pid, fn state ->
      %{
        state
        | speculation: seeded_frame(0, "https://example.test/1.jpg"),
          prerender: %{
            index: 1,
            line: Enum.at(@script, 1),
            status: :director,
            pid: nil,
            new_conv: nil,
            step: nil,
            state_delta: nil,
            frame_msg: nil,
            frame_url: nil,
            frame_route: nil,
            receipt: nil
          }
      }
    end)

    state = :sys.get_state(pid)
    sid = state.session_id
    assert %{index: 1, status: :director} = state.prerender

    # Confirm line 0 was sung -> reveals it -> speculate_next(1) runs and finds
    # line 1 being rendered by the chain, NOT yet in the cache. It must install
    # a placeholder, not spawn a second, competing Director call for line 1.
    sing(pid, "line one")

    state = :sys.get_state(pid)
    assert state.script_cursor == 0
    assert %{index: 1, status: :pending_prerender, confirmed: false, pid: nil} = state.speculation
    # The chain's own in-flight render for line 1 is untouched — same pid slot.
    assert %{index: 1, status: :director} = state.prerender

    # The singer reaches line 1 BEFORE the chain's render finishes.
    sing(pid, "line two")
    state = :sys.get_state(pid)
    assert %{index: 1, status: :pending_prerender, confirmed: true} = state.speculation
    assert state.script_cursor == 1

    # NOW the chain's render lands. It must promote straight into the active
    # slot (not the cache) and reveal immediately, since it was already
    # confirmed while still rendering.
    land_prerender_director(
      pid,
      sid,
      1,
      state.director_conversation,
      "https://example.test/1.jpg",
      %{}
    )

    state = :sys.get_state(pid)
    assert %{index: 1, status: :image} = state.prerender

    land_prerender_image(pid, sid, 1, "https://example.test/2.jpg")
    state = :sys.get_state(pid)

    assert state.last_image_url == "https://example.test/2.jpg"
    # Revealed and cleared -> the slot moved on to look ahead at line 2.
    refute match?(%{index: 1}, state.speculation)
    assert state.prerender == nil
  end

  test "reloading lyrics clears any in-flight prerender chain", %{pid: pid} do
    System.put_env("LOOKAHEAD_DEPTH", "3")
    seed_bootstrap(pid)
    load_script(pid)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | speculation: seeded_frame(0, "https://example.test/1.jpg"),
          prerendered: %{1 => seeded_frame(1, "https://example.test/2.jpg")}
      }
    end)

    assert map_size(:sys.get_state(pid).prerendered) == 1

    load_script(pid)
    state = :sys.get_state(pid)
    assert state.speculation == nil
    assert state.prerender == nil
    assert state.prerendered == %{}
  end
end
