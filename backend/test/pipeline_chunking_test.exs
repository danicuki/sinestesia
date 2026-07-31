defmodule Sinestesia.PipelineChunkingTest do
  @moduledoc """
  State-machine invariants for scene chunking (Sinestesia.LyricsChunker):
  every render/reveal target is a CHUNK (possibly several physical lines),
  not always exactly one line — the fix for HANDOFF gotcha #37's remaining
  cost (a too-thin single-line bootstrap sometimes drawing something
  nonsensical) and for #38's multi-line-utterance case being handled at the
  SOURCE (chunk boundaries chosen for visual coherence) rather than only
  reconciled after the fact.

  No network: the real LLM call always fails fast with :no_key in this test
  env (no GOOGLE/ANTHROPIC keys set), so `load_lyrics/3`'s synchronous
  one-chunk-per-line fallback is what every test observes unless it directly
  overrides `state.chunks` via :sys.replace_state to simulate "the LLM
  already decided" — exactly the pattern pipeline_bootstrap_test.exs and
  pipeline_deep_lookahead_test.exs already use for deterministic state
  machine testing.
  """
  use ExUnit.Case, async: false

  setup do
    prev = %{
      stt: System.get_env("STT_PROVIDER"),
      look: System.get_env("SPECULATIVE_LOOKAHEAD")
    }

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

  # A harmless, never-completing process to stand in for a real Task pid.
  defp fake_pid, do: spawn(fn -> Process.sleep(:infinity) end)

  defp seed_bootstrap(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | bootstrap_done?: true, last_image_url: "https://example.test/bootstrap.jpg"}
    end)
  end

  describe "load_lyrics/3 populates a safe fallback immediately" do
    test "chunks default to one per line, matching the pre-chunking behavior exactly", %{
      pid: pid
    } do
      Sinestesia.Pipeline.set_lyrics(pid, "Numa folha qualquer\nEu desenho um sol amarelo")

      state = :sys.get_state(pid)

      assert state.chunks == [
               %{start_line: 0, end_line: 0, text: "Numa folha qualquer"},
               %{start_line: 1, end_line: 1, text: "Eu desenho um sol amarelo"}
             ]
    end

    test "the eager bootstrap targets the fallback's first chunk (one line) the instant lyrics load",
         %{pid: pid} do
      Sinestesia.Pipeline.set_lyrics(pid, "Numa folha qualquer\nEu desenho um sol amarelo")

      state = :sys.get_state(pid)

      assert %{status: :director, target_index: 0, text: "Numa folha qualquer"} =
               state.bootstrap_speculation
    end
  end

  describe "upgrading from the fallback to a real chunking result" do
    test "a resolved chunking result re-arms the bootstrap on the REAL first chunk, if it hasn't fired yet",
         %{pid: pid} do
      Sinestesia.Pipeline.set_lyrics(
        pid,
        "Numa folha qualquer\nEu desenho um sol amarelo\nE com cinco ou seis retas"
      )

      state = :sys.get_state(pid)
      sid = state.session_id

      # Simulate the fallback-based render having NOT committed yet (e.g. it
      # hadn't started, or was discarded) — the chunking result, once it
      # resolves, should be the one deciding the target. Also bump
      # chunk_generation: this test env has no API keys, so the REAL
      # chunking Task set_lyrics/3 spawned is already racing toward its own
      # {:error, :no_key} result under the OLD generation — bumping first
      # makes that (now-stale) result get dropped instead of clobbering the
      # one this test sends below.
      gen = state.chunk_generation + 1

      :sys.replace_state(pid, fn s -> %{s | bootstrap_speculation: nil, chunk_generation: gen} end)

      chunks = [
        %{start_line: 0, end_line: 1, text: "Numa folha qualquer Eu desenho um sol amarelo"},
        %{start_line: 2, end_line: 2, text: "E com cinco ou seis retas"}
      ]

      send(pid, {:lyrics_chunked, {:ok, chunks}, sid, gen})

      state = :sys.get_state(pid)
      assert state.chunks == chunks

      assert %{
               status: :director,
               target_index: 1,
               text: "Numa folha qualquer Eu desenho um sol amarelo"
             } = state.bootstrap_speculation
    end

    test "a bootstrap already in flight on the FALLBACK is re-targeted onto the real chunk",
         %{pid: pid} do
      # The case that actually happens live, every time: load_lyrics/3 fires
      # the eager bootstrap synchronously against the one-line-per-scene
      # fallback, so the chunking result ALWAYS arrives with a render already
      # in flight. Before HANDOFF gotcha #42 this was a no-op, which meant a
      # successful chunking could never improve the one frame it exists to
      # fix.
      Sinestesia.Pipeline.set_lyrics(pid, "Numa folha qualquer\nEu desenho um sol amarelo")

      state = :sys.get_state(pid)
      assert %{target_index: 0, text: "Numa folha qualquer"} = state.bootstrap_speculation
      sid = state.session_id

      # Bump chunk_generation first: set_lyrics/2 spawned a REAL chunking Task
      # that is already racing toward its own {:error, :no_key} in this
      # key-less test env, and it would otherwise land under the SAME
      # generation and clobber the result this test sends below.
      gen = state.chunk_generation + 1
      :sys.replace_state(pid, fn s -> %{s | chunk_generation: gen} end)

      chunks = [
        %{start_line: 0, end_line: 1, text: "Numa folha qualquer Eu desenho um sol amarelo"}
      ]

      send(pid, {:lyrics_chunked, {:ok, chunks}, sid, gen})

      state = :sys.get_state(pid)
      assert state.chunks == chunks

      assert %{
               status: :director,
               target_index: 1,
               text: "Numa folha qualquer Eu desenho um sol amarelo"
             } = state.bootstrap_speculation
    end

    test "a bootstrap the singer has ALREADY reached is not re-targeted out from under her",
         %{pid: pid} do
      # Once confirmed, the held frame is wanted NOW. Restarting the render
      # would swap a ready, slightly thin opening for a better one that lands
      # after the moment it was needed — the wrong trade on stage.
      Sinestesia.Pipeline.set_lyrics(pid, "Numa folha qualquer\nEu desenho um sol amarelo")

      state = :sys.get_state(pid)
      sid = state.session_id

      # Same real-Task race as the test above — bump the generation so only
      # this test's own synthetic result can land.
      gen = state.chunk_generation + 1

      :sys.replace_state(pid, fn s ->
        %{
          s
          | chunk_generation: gen,
            bootstrap_speculation: %{s.bootstrap_speculation | confirmed: true}
        }
      end)

      chunks = [
        %{start_line: 0, end_line: 1, text: "Numa folha qualquer Eu desenho um sol amarelo"}
      ]

      send(pid, {:lyrics_chunked, {:ok, chunks}, sid, gen})

      state = :sys.get_state(pid)
      assert state.chunks == chunks

      assert %{target_index: 0, text: "Numa folha qualquer", confirmed: true} =
               state.bootstrap_speculation
    end

    test "a chunking failure falls back to one chunk per line and still unblocks the bootstrap",
         %{pid: pid} do
      Sinestesia.Pipeline.set_lyrics(pid, "Numa folha qualquer\nEu desenho um sol amarelo")
      state = :sys.get_state(pid)
      sid = state.session_id
      gen = state.chunk_generation

      :sys.replace_state(pid, fn s -> %{s | bootstrap_speculation: nil} end)

      send(pid, {:lyrics_chunked, {:error, :all_failed}, sid, gen})

      state = :sys.get_state(pid)
      assert state.chunks == Sinestesia.LyricsChunker.fallback(state.script)
      assert %{status: :director, target_index: 0} = state.bootstrap_speculation
    end

    test "a stale chunking result (wrong session) is dropped", %{pid: pid} do
      Sinestesia.Pipeline.set_lyrics(pid, "Numa folha qualquer\nEu desenho um sol amarelo")
      state = :sys.get_state(pid)
      gen = state.chunk_generation

      send(pid, {:lyrics_chunked, {:ok, [%{start_line: 0, end_line: 1, text: "stale"}]}, -1, gen})

      state2 = :sys.get_state(pid)
      assert state2.chunks == state.chunks
    end

    test "a stale chunking result (wrong generation — a reload happened) is dropped", %{pid: pid} do
      Sinestesia.Pipeline.set_lyrics(pid, "Numa folha qualquer\nEu desenho um sol amarelo")
      state = :sys.get_state(pid)
      sid = state.session_id
      stale_gen = state.chunk_generation

      # A reload bumps chunk_generation.
      Sinestesia.Pipeline.set_lyrics(pid, "totally different lyrics")
      fresh_chunks = :sys.get_state(pid).chunks

      send(
        pid,
        {:lyrics_chunked, {:ok, [%{start_line: 0, end_line: 0, text: "stale"}]}, sid, stale_gen}
      )

      assert :sys.get_state(pid).chunks == fresh_chunks
    end
  end

  describe "ongoing speculation over a multi-line chunk" do
    @script ["line one", "line two", "line three", "line four"]

    defp seed_chunk_speculation(pid) do
      Sinestesia.Pipeline.set_lyrics(pid, @script)
      seed_bootstrap(pid)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | # Bump chunk_generation: this test env has no API keys, so the
            # real chunking Task set_lyrics/3 already spawned is racing
            # toward its own {:error, :no_key} result under the OLD
            # generation. Left unbumped, that (now-stale) result can land at
            # ANY point during this test and silently overwrite the custom
            # chunks/speculation seeded below with the plain fallback — the
            # exact class of real-Task race pipeline_bootstrap_test.exs's
            # moduledoc already warns about, just for a new async source.
            chunk_generation: state.chunk_generation + 1,
            script_cursor: 0,
            chunks: [
              %{start_line: 0, end_line: 0, text: "line one"},
              %{start_line: 1, end_line: 2, text: "line two line three"},
              %{start_line: 3, end_line: 3, text: "line four"}
            ],
            speculation: %{
              index: 2,
              line: "line two line three",
              status: :ready,
              confirmed: false,
              pid: fake_pid(),
              new_conv: nil,
              step: nil,
              state_delta: nil,
              frame_msg: %{type: "image", url: "https://example.test/chunk.jpg"},
              frame_url: "https://example.test/chunk.jpg",
              frame_route: nil,
              receipt: nil
            }
        }
      end)
    end

    test "confirming only the FIRST line of a 2-line chunk does not reveal or discard it", %{
      pid: pid
    } do
      seed_chunk_speculation(pid)

      sing(pid, "line two")

      state = :sys.get_state(pid)
      assert state.script_cursor == 1
      # Still held, untouched — the chunk isn't done yet, not a wrong guess.
      assert %{index: 2, status: :ready, frame_url: "https://example.test/chunk.jpg"} =
               state.speculation

      refute state.last_image_url == "https://example.test/chunk.jpg"
    end

    test "confirming the REST of the chunk reveals the held frame", %{pid: pid} do
      seed_chunk_speculation(pid)

      sing(pid, "line two")
      sing(pid, "line three")

      state = :sys.get_state(pid)
      assert state.script_cursor == 2
      assert state.last_image_url == "https://example.test/chunk.jpg"
      # reveal_speculation/1 immediately looks ahead again — the held chunk
      # frame is gone, replaced by a fresh speculation for whatever comes
      # after it (line 4), not left nil.
      assert %{index: 3} = state.speculation
    end

    test "a whole multi-line chunk sung in ONE breath reveals immediately, on that same utterance",
         %{pid: pid} do
      seed_chunk_speculation(pid)

      # A clean utterance covering BOTH of the chunk's lines scores each of
      # them a perfect 1.0 (the utterance IS their exact concatenation), and
      # match/4 breaks an exact-score tie toward the NEAREST candidate — so it
      # reports line 1, not the chunk's own end_line (2).
      #
      # Before HANDOFF #44 that was read as "still partway through the chunk"
      # and the finished frame was held indefinitely, waiting for a later
      # utterance that may never come. Found live on Aquarela: the singer sang
      # "E se faço chover com dois riscos / Tenho um guarda-chuva" in one
      # breath, stopped, and the umbrella picture — already rendered and
      # sitting in memory — was simply never shown.
      sing(pid, "line two line three")

      state = :sys.get_state(pid)

      # Revealed on THIS utterance, and the cursor is at the chunk's real end
      # so the next look-ahead doesn't re-target a scene already performed.
      assert state.last_image_url == "https://example.test/chunk.jpg"
      assert state.script_cursor == 2
    end

    test "covering only the chunk's OPENING line still waits — that's a real mid-scene pause",
         %{pid: pid} do
      seed_chunk_speculation(pid)

      sing(pid, "line two")

      state = :sys.get_state(pid)
      assert state.script_cursor == 1
      assert %{index: 2, status: :ready} = state.speculation
      refute state.last_image_url == "https://example.test/chunk.jpg"
    end
  end
end
