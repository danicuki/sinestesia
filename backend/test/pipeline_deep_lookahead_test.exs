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

  test "LOOKAHEAD_DEPTH=1 (default): the bootstrap reveal arms one speculation, never a prerender",
       %{pid: pid} do
    # seed_bootstrap BEFORE set_lyrics: bootstrap_done? must already be true
    # when lyrics load, or maybe_speculate_bootstrap/1 would ALSO spawn a real
    # eager-bootstrap Director call (a separate feature, its own test file) and
    # race with this test's synthetic speculation/prerender messages.
    seed_bootstrap(pid)
    Sinestesia.Pipeline.set_lyrics(pid, @script)
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
    Sinestesia.Pipeline.set_lyrics(pid, @script)
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
    # seed_bootstrap BEFORE set_lyrics: bootstrap_done? must already be true
    # when lyrics load, or maybe_speculate_bootstrap/1 would ALSO spawn a real
    # eager-bootstrap Director call (a separate feature, its own test file) and
    # race with this test's synthetic speculation/prerender messages.
    seed_bootstrap(pid)
    Sinestesia.Pipeline.set_lyrics(pid, @script)
    land_bootstrap_image(pid)

    state = :sys.get_state(pid)
    sid = state.session_id
    land_spec_director(pid, sid, 0, state.director_conversation)
    land_spec_image(pid, sid, 0, "https://example.test/1.jpg")

    state = :sys.get_state(pid)

    land_prerender_director(
      pid,
      sid,
      1,
      state.speculation.new_conv,
      state.speculation.frame_url,
      %{}
    )

    land_prerender_image(pid, sid, 1, "https://example.test/2.jpg")

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

  test "off-script singing discards the speculation AND the whole prerender chain",
       %{pid: pid} do
    System.put_env("LOOKAHEAD_DEPTH", "3")
    # seed_bootstrap BEFORE set_lyrics: bootstrap_done? must already be true
    # when lyrics load, or maybe_speculate_bootstrap/1 would ALSO spawn a real
    # eager-bootstrap Director call (a separate feature, its own test file) and
    # race with this test's synthetic speculation/prerender messages.
    seed_bootstrap(pid)
    Sinestesia.Pipeline.set_lyrics(pid, @script)
    land_bootstrap_image(pid)

    state = :sys.get_state(pid)
    sid = state.session_id
    land_spec_director(pid, sid, 0, state.director_conversation)
    land_spec_image(pid, sid, 0, "https://example.test/1.jpg")

    state = :sys.get_state(pid)

    land_prerender_director(
      pid,
      sid,
      1,
      state.speculation.new_conv,
      state.speculation.frame_url,
      %{}
    )

    land_prerender_image(pid, sid, 1, "https://example.test/2.jpg")

    state = :sys.get_state(pid)
    assert map_size(state.prerendered) == 1

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
    # seed_bootstrap BEFORE set_lyrics: bootstrap_done? must already be true
    # when lyrics load, or maybe_speculate_bootstrap/1 would ALSO spawn a real
    # eager-bootstrap Director call (a separate feature, its own test file) and
    # race with this test's synthetic speculation/prerender messages.
    seed_bootstrap(pid)
    Sinestesia.Pipeline.set_lyrics(pid, @script)
    land_bootstrap_image(pid)

    state = :sys.get_state(pid)
    sid = state.session_id
    land_spec_director(pid, sid, 0, state.director_conversation)
    land_spec_image(pid, sid, 0, "https://example.test/1.jpg")

    # The chain auto-deepens: a prerender for line 1 is now in flight but NOT
    # finished — confirm that precondition before the real test.
    state = :sys.get_state(pid)
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
    # seed_bootstrap BEFORE set_lyrics: bootstrap_done? must already be true
    # when lyrics load, or maybe_speculate_bootstrap/1 would ALSO spawn a real
    # eager-bootstrap Director call (a separate feature, its own test file) and
    # race with this test's synthetic speculation/prerender messages.
    seed_bootstrap(pid)
    Sinestesia.Pipeline.set_lyrics(pid, @script)
    land_bootstrap_image(pid)

    state = :sys.get_state(pid)
    sid = state.session_id
    land_spec_director(pid, sid, 0, state.director_conversation)
    land_spec_image(pid, sid, 0, "https://example.test/1.jpg")

    state = :sys.get_state(pid)

    land_prerender_director(
      pid,
      sid,
      1,
      state.speculation.new_conv,
      state.speculation.frame_url,
      %{}
    )

    land_prerender_image(pid, sid, 1, "https://example.test/2.jpg")

    assert map_size(:sys.get_state(pid).prerendered) == 1

    Sinestesia.Pipeline.set_lyrics(pid, @script)
    state = :sys.get_state(pid)
    assert state.speculation == nil
    assert state.prerender == nil
    assert state.prerendered == %{}
  end
end
