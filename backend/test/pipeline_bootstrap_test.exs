defmodule Sinestesia.PipelineBootstrapTest do
  @moduledoc """
  State-machine invariants for the EAGER bootstrap (SPECULATIVE_LOOKAHEAD):
  loading lyrics with no singing yet should immediately start pre-rendering
  the opening from the pasted lyrics themselves, hold it, and reveal it only
  once REAL singing independently reaches the same word threshold the
  reactive bootstrap has always used — never before, and never twice.

  This exists because the original implementation only ever started ANY
  look-ahead work after the reactive bootstrap had already fired from real STT
  accumulation — meaning loading lyrics before singing began did nothing until
  the singer had already produced 15+ words. Caught by the user testing live;
  this test file locks in the fix.

  A note on determinism, learned the hard way: a synthetic
  `bootstrap_spec_director_done` SUCCESS message still spawns a REAL
  image-generation Task as a side effect (that's the actual production code
  path — only the Director half is faked). If a test then ALSO sends its own
  synthetic `bootstrap_spec_image_done` for the same slot, the two race, and
  which one the pipeline processes first depends on real scheduler/network
  timing — not a property of the feature, but of the test. So: only the first
  two tests let `set_lyrics` spawn anything real, and check state immediately
  with no further steps that depend on its outcome. Every other test seeds
  `bootstrap_speculation` directly at whatever status it needs via
  `:sys.replace_state`, so no real Task ever exists to race against.
  """
  use ExUnit.Case, async: false

  @script [
    "Numa folha qualquer eu desenho um sol amarelo",
    "E com cinco ou seis retas é fácil fazer um castelo",
    "Corro o lápis em torno da mão e me dou uma luva",
    "E se faço chover com dois riscos tenho um guarda-chuva"
  ]

  setup do
    prev = %{
      stt: System.get_env("STT_PROVIDER"),
      look: System.get_env("SPECULATIVE_LOOKAHEAD")
    }

    System.put_env("STT_PROVIDER", "replay")
    System.delete_env("REPLAY_FILE")
    System.delete_env("SPECULATIVE_LOOKAHEAD")

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

  defp now_ms, do: System.system_time(:millisecond)

  defp base_timings do
    %{
      stt_ms: nil,
      stt_provider: nil,
      director_ms: 0,
      director_queue_ms: 0,
      image_started_at: now_ms() - 200,
      image_call_ms: 200,
      lyric: "test",
      verification: nil
    }
  end

  # A harmless, never-completing process to stand in for a real Task pid —
  # enough for discard_bootstrap_speculation/1's Process.alive?/exit checks
  # without any real network call ever happening.
  defp fake_pid, do: spawn(fn -> Process.sleep(:infinity) end)

  # Deterministically install a bootstrap_speculation at whatever status a test
  # needs, WITHOUT going through the real set_lyrics -> maybe_speculate_bootstrap
  # -> director-done -> image-spawn chain — see the moduledoc note on why.
  defp seed_bootstrap_speculation(pid, overrides \\ %{}) do
    base = %{
      status: :director,
      confirmed: false,
      pid: fake_pid(),
      new_conv: nil,
      step: nil,
      state_delta: nil,
      frame_msg: nil,
      frame_url: nil,
      frame_route: nil,
      receipt: nil,
      text: "fake opening text",
      # Arbitrary for these tests — nothing here exercises the real target
      # selection (that's pipeline_bootstrap_test.exs's own dedicated tests).
      target_index: 1
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | script: @script,
          script_active?: true,
          # Seeded directly (bypassing load_lyrics/3, see the moduledoc) —
          # the real code always populates this the instant lyrics load, so
          # it must be seeded here too, or bootstrap_content_and_target/1
          # sees an empty chunk list and never re-arms.
          chunks: Sinestesia.LyricsChunker.fallback(@script),
          bootstrap_generation: state.bootstrap_generation + 1,
          bootstrap_speculation: Map.merge(base, overrides)
      }
    end)

    :sys.get_state(pid)
  end

  defp land_bootstrap_spec_image(pid, sid, gen, url) do
    send(
      pid,
      {:bootstrap_spec_image_done, {:ok, url, [], "opening prompt"}, base_timings(), sid, gen}
    )
  end

  defp sing(pid, text), do: send(pid, {:transcript, :replay, text, true, 0})

  test "SPECULATIVE_LOOKAHEAD off: loading lyrics never starts an eager bootstrap", %{pid: pid} do
    Sinestesia.Pipeline.set_lyrics(pid, @script)
    state = :sys.get_state(pid)
    assert state.bootstrap_speculation == nil
  end

  test "SPECULATIVE_LOOKAHEAD on: loading lyrics with NOTHING sung yet starts one immediately",
       %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    Sinestesia.Pipeline.set_lyrics(pid, @script)

    state = :sys.get_state(pid)
    assert %{status: :director} = state.bootstrap_speculation
    assert state.bootstrap_generation == 1
    # Real singing hasn't started — cursor, bootstrap_done? are untouched.
    assert state.script_cursor == -1
    refute state.bootstrap_done?
  end

  test "an :image-status render HOLDS once ready if real singing hasn't reached the threshold",
       %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    state = seed_bootstrap_speculation(pid, %{status: :image})
    sid = state.session_id
    gen = state.bootstrap_generation

    land_bootstrap_spec_image(pid, sid, gen, "https://example.test/opening.jpg")

    state = :sys.get_state(pid)

    assert %{status: :ready, confirmed: false, frame_url: "https://example.test/opening.jpg"} =
             state.bootstrap_speculation

    # Nothing revealed yet — real singing hasn't caught up.
    refute state.bootstrap_done?
    assert state.last_image_url == nil
    refute_received {:push_json, %{type: "image"}}
  end

  test "reveals as soon as real singing reaches the threshold, WITHOUT firing a second Director call",
       %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    state = seed_bootstrap_speculation(pid, %{status: :image})
    sid = state.session_id
    gen = state.bootstrap_generation

    land_bootstrap_spec_image(pid, sid, gen, "https://example.test/opening.jpg")

    # Sing enough of the actual opening lines to cross @bootstrap_min_words (15).
    sing(pid, "Numa folha qualquer eu desenho um sol amarelo")
    sing(pid, "E com cinco ou seis retas é fácil fazer um castelo")

    state = :sys.get_state(pid)
    assert state.bootstrap_done? == true
    assert state.last_image_url == "https://example.test/opening.jpg"
    assert state.bootstrap_speculation == nil
    # Cursor caught up to reflect what was ACTUALLY sung, via furthest_match —
    # not left at -1 just because the render came from the pasted script.
    assert state.script_cursor >= 1
    # generating? must be false — no competing reactive Director call in flight.
    assert state.generating? == false
  end

  test "real singing reaching the threshold marks it confirmed WITHOUT revealing early",
       %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    # Still rendering (status: :director) — deterministic, no real Task exists.
    state = seed_bootstrap_speculation(pid)

    sing(pid, "Numa folha qualquer eu desenho um sol amarelo")
    sing(pid, "E com cinco ou seis retas é fácil fazer um castelo")

    state2 = :sys.get_state(pid)
    assert %{status: :director, confirmed: true} = state2.bootstrap_speculation
    assert state2.bootstrap_generation == state.bootstrap_generation
    refute state2.bootstrap_done?
    refute_received {:push_json, %{type: "image"}}
  end

  test "an already-confirmed render reveals the INSTANT it finishes", %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    state = seed_bootstrap_speculation(pid, %{status: :image, confirmed: true})
    sid = state.session_id
    gen = state.bootstrap_generation

    land_bootstrap_spec_image(pid, sid, gen, "https://example.test/opening.jpg")

    state = :sys.get_state(pid)
    assert state.bootstrap_done? == true
    assert state.last_image_url == "https://example.test/opening.jpg"
    assert state.bootstrap_speculation == nil
  end

  test "a Director error falls back cleanly to the ordinary reactive bootstrap", %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    state = seed_bootstrap_speculation(pid)
    sid = state.session_id
    gen = state.bootstrap_generation

    send(pid, {:bootstrap_spec_director_done, {:error, :timeout}, now_ms(), 10, nil, sid, gen})

    state = :sys.get_state(pid)
    assert state.bootstrap_speculation == nil
    refute state.bootstrap_done?
    refute state.generating?
  end

  test "an image error falls back cleanly to the ordinary reactive bootstrap", %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    state = seed_bootstrap_speculation(pid, %{status: :image})
    sid = state.session_id
    gen = state.bootstrap_generation

    send(pid, {:bootstrap_spec_image_done, {:error, :timeout}, base_timings(), sid, gen})

    state = :sys.get_state(pid)
    assert state.bootstrap_speculation == nil
    refute state.bootstrap_done?
  end

  test "off-script singing discards a HELD eager bootstrap instead of blocking forever", %{
    pid: pid
  } do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")

    state =
      seed_bootstrap_speculation(pid, %{
        status: :ready,
        frame_url: "https://example.test/opening.jpg",
        frame_msg: %{type: "image", url: "https://example.test/opening.jpg"}
      })

    refute state.bootstrap_done?

    # Caught live: the operator had @script loaded but the performance was a
    # COMPLETELY different song. Before the fix, `bootstrap_target_reached?`
    # (its own from-scratch furthest_match over `state.lyrics`) never crossed
    # the threshold, and `maybe_trigger`'s bootstrap branch had no other
    # escape hatch — the pipeline sat silent forever, no matter how many real
    # words were spoken, because a non-nil `bootstrap_speculation` blocks
    # EVERYTHING (reveal AND reactive fallback) until its own target is
    # reached.
    sing(pid, "Olha que coisa mais linda mais cheia de graça")

    state = :sys.get_state(pid)
    # The held eager render is abandoned — it was a bet on the wrong content.
    assert state.bootstrap_speculation == nil
    refute state.bootstrap_done?
    refute_received {:push_json, %{type: "image"}}

    # Sing enough more (still off-script) to cross the ordinary reactive
    # bootstrap's word threshold (@bootstrap_min_words = 15) — proving the
    # pipeline fell back into the SAME plain reactive path it would use if no
    # script had ever been loaded, instead of staying stuck.
    sing(pid, "que vem e que passa num doce balanco a caminho do mar")

    state = :sys.get_state(pid)
    assert state.generating? == true
  end

  test "a stale completion from a discarded attempt (wrong generation) is dropped, not adopted",
       %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    state = seed_bootstrap_speculation(pid, %{status: :image})
    sid = state.session_id
    stale_gen = state.bootstrap_generation

    # Simulate a lyrics reload: a fresh attempt starts (generation bumps)...
    fresh = seed_bootstrap_speculation(pid)
    assert fresh.bootstrap_generation == stale_gen + 1

    # ...then the OLD (discarded) attempt's result finally lands. It must be
    # ignored — the current bootstrap_speculation is a DIFFERENT (fresh) one,
    # not even the same status.
    land_bootstrap_spec_image(pid, sid, stale_gen, "https://example.test/stale.jpg")

    state = :sys.get_state(pid)
    # Still the fresh one, untouched — not clobbered by the stale message.
    assert %{status: :director} = state.bootstrap_speculation
    assert state.bootstrap_generation == stale_gen + 1
    refute state.bootstrap_done?
  end

  test "reloading lyrics discards an in-flight eager bootstrap and starts a fresh one", %{
    pid: pid
  } do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    Sinestesia.Pipeline.set_lyrics(pid, @script)

    first = :sys.get_state(pid).bootstrap_speculation
    assert %{status: :director, pid: first_pid} = first
    assert Process.alive?(first_pid)

    Sinestesia.Pipeline.set_lyrics(pid, @script)

    state = :sys.get_state(pid)
    assert %{status: :director} = state.bootstrap_speculation
    assert state.bootstrap_generation == 2
    # The old attempt's Task is killed on discard.
    refute Process.alive?(first_pid)
  end

  test "the eager bootstrap targets the song's first LINE, never a whole stanza or a word count",
       %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")

    raw = """
    Numa folha qualquer eu desenho um sol amarelo

    E com cinco ou seis retas é fácil fazer um castelo
    Corro o lápis em torno da mão e me dou uma luva
    """

    Sinestesia.Pipeline.set_lyrics(pid, raw)
    state = :sys.get_state(pid)

    assert length(state.structure.sections) == 2
    assert %{target_index: 0} = state.bootstrap_speculation

    # Confirm ONLY the first (8-word) line — well under the old fixed 15-word
    # threshold — and it must already be enough to reveal once ready.
    sid = state.session_id
    gen = state.bootstrap_generation

    :sys.replace_state(pid, fn s ->
      %{s | bootstrap_speculation: %{s.bootstrap_speculation | status: :image}}
    end)

    land_bootstrap_spec_image(pid, sid, gen, "https://example.test/opening.jpg")

    sing(pid, "Numa folha qualquer eu desenho um sol amarelo")

    state = :sys.get_state(pid)
    assert state.bootstrap_done? == true
    assert state.last_image_url == "https://example.test/opening.jpg"
  end

  test "a LONGER real first stanza still only targets its OWN first line, not the rest of it",
       %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")

    raw = """
    Numa folha qualquer eu desenho um sol amarelo
    E com cinco ou seis retas é fácil fazer um castelo
    Corro o lápis em torno da mão e me dou uma luva

    Vai vai vai, aquarela do Brasil
    """

    Sinestesia.Pipeline.set_lyrics(pid, raw)
    state = :sys.get_state(pid)

    # A real 3-line stanza — but the target is STILL just line 0, regardless
    # of how many lines the natural stanza actually has. Two earlier attempts
    # (see HANDOFF gotchas #29, #36) both still hard-coded some threshold
    # (first a fixed word count, then a fixed word count capped per stanza)
    # and both turned out to still be waiting too long on a real song — a
    # "stanza" is a formatting artifact, not the coherent unit that matters.
    assert %{target_index: 0} = state.bootstrap_speculation

    sid = state.session_id
    gen = state.bootstrap_generation

    :sys.replace_state(pid, fn s ->
      %{s | bootstrap_speculation: %{s.bootstrap_speculation | status: :image}}
    end)

    land_bootstrap_spec_image(pid, sid, gen, "https://example.test/opening.jpg")

    # The FIRST line alone (8 words) is already enough to reveal — no need to
    # wait for the stanza's other two lines at all.
    sing(pid, "Numa folha qualquer eu desenho um sol amarelo")
    assert :sys.get_state(pid).bootstrap_done? == true
  end

  test "a genuinely long stanza (Aquarela's real 8-line first verse) only waits for its first line",
       %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")

    # Modeled directly on the live report: Aquarela's real first verse has no
    # internal blank-line break, so MusicalStructure.analyze/1 groups all 8
    # short lines into ONE stanza. Before this fix, the eager bootstrap held
    # the opening frame until MULTIPLE of these 8 lines were confirmed sung
    # (first all 8, then a word-count-capped subset) — several tens of
    # seconds of continuous singing before anything appeared on stage.
    raw = """
    Numa folha qualquer
    Eu desenho um sol amarelo
    E com cinco ou seis retas
    É fácil fazer um castelo
    Corro o lápis em torno da mão
    E me dou uma luva
    E se faço chover com dois riscos
    Tenho um guarda-chuva

    Se um pinguinho de tinta
    """

    Sinestesia.Pipeline.set_lyrics(pid, raw)
    state = :sys.get_state(pid)

    # Only 3 words ("Numa folha qualquer") — genuinely tiny, but it is the
    # song's REAL opening fragment, not a truncated STT guess, and it's the
    # one unit that needs no per-song tuning to identify.
    assert %{target_index: 0, text: "Numa folha qualquer"} = state.bootstrap_speculation
  end

  test "reset_song (new song) re-arms the eager bootstrap when lyrics persist", %{pid: pid} do
    System.put_env("SPECULATIVE_LOOKAHEAD", "on")
    state = seed_bootstrap_speculation(pid, %{status: :image})
    sid = state.session_id
    gen = state.bootstrap_generation

    land_bootstrap_spec_image(pid, sid, gen, "https://example.test/opening.jpg")
    sing(pid, "Numa folha qualquer eu desenho um sol amarelo")
    sing(pid, "E com cinco ou seis retas é fácil fazer um castelo")

    assert :sys.get_state(pid).bootstrap_done? == true

    Sinestesia.Pipeline.reset_song(pid)

    state = :sys.get_state(pid)
    assert state.bootstrap_done? == false
    assert state.script == @script
    # The next song's opening is already pre-rendering, same as the first.
    assert %{status: :director} = state.bootstrap_speculation
  end
end
