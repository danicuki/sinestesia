defmodule Sinestesia.DirectorBenchTest do
  @moduledoc """
  The Director bench scores what the stage would have received, so its scoring
  and the Director's per-model request shape are pinned here — a wrong thinking
  switch is a 400 on every turn of a show, not a bench curiosity.
  """
  # Not async: element_words/0 reads the environment.
  use ExUnit.Case, async: false

  alias Sinestesia.Director
  alias Sinestesia.DirectorBench

  describe "classify/2 — the compose contract" do
    test "exactly one NEW with a known position, or one ATMOS, is well-formed" do
      for pos <- Director.placements() do
        assert DirectorBench.classify("NEW: a round yellow sun | POS: #{pos}", :compose) == :new
      end

      assert DirectorBench.classify("  ATMOS: a gentle sense of upward drift\n", :compose) ==
               :atmos

      assert DirectorBench.classify("NEW: a castle | POS: Right", :compose) == :new
    end

    test "what parse_story would salvage on stage still counts as off-contract" do
      # Each of these reaches the image model as a fragment today.
      assert DirectorBench.classify("NEW: a sailboat", :compose) == :invalid
      assert DirectorBench.classify("NEW: a sailboat | POS: middle", :compose) == :invalid
      assert DirectorBench.classify("**NEW:** a sailboat | POS: left", :compose) == :invalid

      assert DirectorBench.classify(
               "NEW: a sailboat | POS: left\nNEW: a gull | POS: top",
               :compose
             ) == :invalid

      assert DirectorBench.classify("ATMOS: a heavy haze | POS: center", :compose) == :invalid
      assert DirectorBench.classify("Sure! Here is the element:", :compose) == :invalid
    end

    test "the global prompt wants one line of at most 30 words" do
      assert DirectorBench.classify("turtle in river, plus an old man smoking a pipe", :global) ==
               :scene

      assert DirectorBench.classify(Enum.map_join(1..31, " ", &"w#{&1}"), :global) == :invalid
      assert DirectorBench.classify("a\nb", :global) == :invalid
    end
  end

  describe "score/2" do
    test "reads the element, its position and its length" do
      assert %{
               kind: :new,
               element: "a woman dancing in a flowing red dress",
               pos: "left",
               words: 8
             } =
               DirectorBench.score(
                 "NEW: a woman dancing in a flowing red dress | POS: left",
                 :compose
               )

      assert %{kind: :atmos, pos: nil, words: 6} =
               DirectorBench.score("ATMOS: a gentle sense of upward drift", :compose)

      assert %{kind: :invalid, element: nil} =
               DirectorBench.score("I cannot see the song", :compose)
    end
  end

  describe "price/1 and cost_per_show/1" do
    test "the longest matching prefix prices a model, snapshots included" do
      assert DirectorBench.price("gemini-3.5-flash-lite") == {0.30, 2.50}
      assert DirectorBench.price("gpt-6-luna-2026-05-18") == {0.10, 0.50}
      assert DirectorBench.price("claude-haiku-5-5") == {0.10, 0.50}
      assert DirectorBench.price("gemma4:12b-mlx") == nil
    end

    test "a show is 600 turns at the measured token counts, list price" do
      rows =
        for _ <- 1..4,
            do: %{"model" => "claude-haiku-5-5", "in_tokens" => 1_000, "out_tokens" => 30}

      # 600 × (1000 × 0.10 + 30 × 0.50) / 1e6
      assert_in_delta DirectorBench.cost_per_show(rows), 0.069, 1.0e-9

      assert DirectorBench.cost_per_show([
               %{"model" => "gemma4:12b", "in_tokens" => 900, "out_tokens" => 20}
             ]) == nil

      assert DirectorBench.cost_per_show([
               %{"model" => "gpt-6-luna", "in_tokens" => nil, "out_tokens" => nil}
             ]) == nil
    end
  end

  describe "summarize/2" do
    test "latency percentiles, budget overruns, format and position repeats" do
      rows =
        for {ms, kind, pos, repeat} <- [
              {400, "new", "top", false},
              {600, "new", "top", true},
              {900, "atmos", nil, false},
              {3_500, "invalid", nil, false}
            ] do
          %{
            "variant" => "x",
            "provider" => "gemini",
            "model" => "gemini-3.5-flash-lite",
            "turn" => 1,
            "ms" => ms,
            "over_budget" => ms > 3_000,
            "kind" => kind,
            "pos" => pos,
            "repeat_pos" => repeat,
            "words" => 5,
            "in_tokens" => 800,
            "out_tokens" => 20,
            "cut" => false,
            "error" => nil
          }
        end

      s = DirectorBench.summarize("x", rows)
      assert s.turns == 4 and s.errors == 0
      assert s.p50 == 600 and s.p95 == 3_500
      assert_in_delta s.over_budget, 0.25, 1.0e-9
      assert_in_delta s.valid, 0.75, 1.0e-9
      assert s.pos_repeats == 1
      assert s.cost_per_show > 0

      # Content per second of waiting: 5 words over the well-formed turns' round
      # trips (400/600/900 ms → 12.5/8.3/5.6 words/s, median 8.3); tokens over all.
      assert_in_delta s.words_per_s, 5 * 1000 / 600, 1.0e-9
      assert_in_delta s.out_tps, 20 * 1000 / 900, 1.0e-9
    end

    test "failed turns are counted, not averaged in" do
      rows = [
        %{
          "variant" => "x",
          "provider" => "haiku",
          "model" => "m",
          "turn" => 0,
          "ms" => 100,
          "kind" => "new",
          "error" => nil
        },
        %{
          "variant" => "x",
          "provider" => "haiku",
          "model" => "m",
          "turn" => 1,
          "ms" => 60_000,
          "kind" => "error",
          "error" => "HTTP 404: no such model"
        }
      ]

      s = DirectorBench.summarize("x", rows)
      assert s.errors == 1 and s.p50 == 100
      assert s.error_messages == ["HTTP 404: no such model"]
    end
  end

  describe "report/2" do
    test "answers the questions in sentences before the table" do
      row = fn variant, provider, model, ms, kind, over ->
        %{
          "variant" => variant,
          "provider" => provider,
          "model" => model,
          "song" => "dinda",
          "turn" => 0,
          "ms" => ms,
          "over_budget" => over,
          "kind" => kind,
          "pos" => "top",
          "repeat_pos" => false,
          "words" => 8,
          "in_tokens" => 900,
          "out_tokens" => 16,
          "words_spec" => "4-12",
          "cut" => false,
          "error" => nil
        }
      end

      rows =
        List.duplicate(row.("gemma:g", "gemma", "gemma4:12b", 400, "invalid", false), 2) ++
          List.duplicate(row.("gemma:g", "gemma", "gemma4:12b", 400, "new", false), 2) ++
          List.duplicate(row.("gemini:f", "gemini", "gemini-3.5-flash-lite", 650, "new", false), 4) ++
          List.duplicate(row.("gemini:a", "gemini", "gemini-4-argon", 3_200, "atmos", true), 4)

      report = DirectorBench.report(rows, [])

      assert report =~ "**Fastest:** `gemma:g`, 400 ms at the median (local). Fastest cloud model: `gemini:f`, 650 ms."
      assert report =~ "kept the format (≥ 95%) and never missed the live budget:** `gemini:f`, 650 ms."
      assert report =~ "**Over the live budget:** `gemini:a` on 100% of turns (p95 3200 ms)"
      assert report =~ "**Off-format replies:** `gemma:g` 50%"
      assert report =~ "**Most content per second of waiting:** `gemma:g`, 20.0 words/s (40.0 out tok/s)."
      assert report =~ "`--words 30-45` measures who writes long elements fastest"
      assert report =~ "**Cheapest cloud model:** `gemini:f`"
      assert report =~ "ranged from 0% (`gemma:g`) to 100% (`gemini:a`)"
      assert report =~ "| words/element | words/s | out tok/s | $/show |"
      assert report =~ "- **ATMOS** — of the well-formed replies"

      # One length per model: nothing to fit, so the report says what to run.
      assert report =~ "### How long can an element be?"
      assert report =~ "One element length measured per model so far."
      refute report =~ "Most words within"
    end

    test "says so when there is nothing to rank" do
      assert DirectorBench.report([], []) =~ "Nothing measured yet."
    end
  end

  describe "length_fit/1 — how far a model can go within the budget" do
    # A model that costs 600 ms before writing, writes 200 tok/s (5 ms a token)
    # and spends 6 tokens of scaffolding plus 1.5 a word.
    defp fit_rows(variant, spec, words, n) do
      tokens = 6 + round(1.5 * words)

      for i <- 1..n do
        %{
          "variant" => variant,
          "provider" => "gemini",
          "model" => "gemini-3.5-flash-lite",
          "prompt" => "compose",
          "song" => "dinda",
          "turn" => i,
          "ms" => 600 + 5 * tokens,
          "kind" => "new",
          "words" => words,
          "words_spec" => spec,
          "out_tokens" => tokens,
          "error" => nil
        }
      end
    end

    test "recovers base and writing speed from two lengths and inverts them per target" do
      rows = fit_rows("gemini:f", "4-12", 8, 5) ++ fit_rows("gemini:f@30-45", "30-45", 40, 5)

      [f] = DirectorBench.length_fit(rows)
      assert f.model == "gemini:f"
      assert f.rows == 10
      assert_in_delta f.base_ms, 600, 1.0e-6
      assert_in_delta f.tok_s, 200, 1.0e-6
      assert_in_delta f.tokens_per_word, 1.5, 1.0e-6
      assert Enum.map(f.specs, &{&1.spec, &1.words}) == [{"4-12", 8}, {"30-45", 40}]

      # (1000 − 600) / 5 = 80 tokens; (80 − 6) / 1.5 = 49.3 words.
      assert f.words_in == %{1_000 => 49, 2_000 => 182, 3_000 => 316}

      report = DirectorBench.report(rows, [])
      assert report =~ "**Most words within 1 s of round trip:** `gemini:f`, about 49 (base 600 ms, writes ~200 tok/s)"
      assert report =~ "| gemini:f | 4-12 → 8 (690 ms), 30-45 → 40 (930 ms) | 600 | 200 | 1.5 | 49 | 182 | 300+ |"
    end

    test "one length is not a fit, nor are replies the model never finished" do
      assert DirectorBench.length_fit(fit_rows("gemini:f", "4-12", 8, 12)) == []

      slow = fit_rows("gemma:g", "4-12", 8, 5) ++ fit_rows("gemma:g@30-45", "30-45", 40, 5)
      broken = Enum.map(slow, &Map.put(&1, "kind", "invalid"))
      assert DirectorBench.length_fit(broken) == []
    end

    test "when the model ignored the longer ask, the report says what it wrote instead" do
      # Asked for 30-45, wrote 8 again: no spread, so no fit — and that is the finding.
      rows = fit_rows("gemini:f", "4-12", 8, 5) ++ fit_rows("gemini:f@30-45", "30-45", 8, 5)
      assert DirectorBench.length_fit(rows) == []

      report = DirectorBench.report(rows, [])
      assert report =~ "no model's replies spread enough to fit"
      assert report =~ "- `gemini:f`: asked 4-12 → wrote 8, 30-45 → wrote 8 words at the median"
    end

    test "a base over the target leaves no room to write" do
      rows =
        (fit_rows("x:m", "4-12", 8, 5) ++ fit_rows("x:m@30-45", "30-45", 40, 5))
        |> Enum.map(&Map.update!(&1, "ms", fn ms -> ms + 1_000 end))

      [f] = DirectorBench.length_fit(rows)
      assert f.words_in[1_000] == 0
      assert DirectorBench.report(rows, []) =~ "no model has room to write anything"
    end

    test "fit/1 is plain least squares" do
      assert {intercept, slope} = DirectorBench.fit([{0, 1}, {1, 3}, {2, 5}])
      assert_in_delta intercept, 1, 1.0e-9
      assert_in_delta slope, 2, 1.0e-9
      assert DirectorBench.fit([{3, 1}, {3, 2}]) == nil
      assert DirectorBench.fit([{1, 1}]) == nil
    end
  end

  describe "Director.thinking_candidates/2 — how each model is told not to think" do
    test "Gemini: a zero budget on 2.5/3.1, minimal on 3.5/3.6, low is the floor on 3.8 and 4" do
      assert [%{thinkingBudget: 0} | _] =
               Director.thinking_candidates(:gemini, "gemini-3.1-flash-lite")

      assert [%{thinkingLevel: "minimal"} | _] =
               Director.thinking_candidates(:gemini, "gemini-3.5-flash-lite")

      assert [%{thinkingLevel: "minimal"} | _] =
               Director.thinking_candidates(:gemini, "gemini-3.6-flash")

      assert [%{thinkingLevel: "low"} | _] =
               Director.thinking_candidates(:gemini, "gemini-3.8-flash")

      assert [%{thinkingLevel: "low"} | _] =
               Director.thinking_candidates(:gemini, "gemini-4-argon")
    end

    test "Anthropic: disabled on Haiku 5.5, between_tools on Sonnet 5.5, effort on Opus 5.5, nothing on 4.5" do
      assert [%{thinking: %{type: "disabled"}} | _] =
               Director.thinking_candidates(:haiku, "claude-haiku-5-5")

      assert [%{thinking: %{type: "between_tools"}} | _] =
               Director.thinking_candidates(:haiku, "claude-sonnet-5-5")

      assert [%{output_config: %{effort: "low"}} | _] =
               Director.thinking_candidates(:haiku, "claude-opus-5-5")

      assert Director.thinking_candidates(:haiku, "claude-haiku-4-5") == [nil]
    end

    test "OpenAI: none on Luna; Astra and 6.1 Sol cannot go below low" do
      assert [%{reasoning_effort: "none"} | _] =
               Director.thinking_candidates(:openai, "gpt-6-luna")

      assert [%{reasoning_effort: "low"} | _] =
               Director.thinking_candidates(:openai, "gpt-6-astra")

      assert [%{reasoning_effort: "low"} | _] =
               Director.thinking_candidates(:openai, "gpt-6.1-sol")
    end

    test "every ladder ends in 'send nothing', so an unknown API shape still gets an answer" do
      for {p, m} <- [
            {:gemma, "gemma4:12b-mlx"},
            {:gemini, "gemini-9-future"},
            {:haiku, "claude-haiku-5-5"},
            {:openai, "gpt-6-luna"},
            {:zerog, "whatever"}
          ] do
        assert List.last(Director.thinking_candidates(p, m)) == nil
      end
    end

    test "always_thinks?/2 names the models whose floor is still reasoning" do
      assert Director.always_thinks?(:gemini, "gemini-4-argon")
      assert Director.always_thinks?(:haiku, "claude-opus-5-5")
      assert Director.always_thinks?(:openai, "gpt-6-astra")
      refute Director.always_thinks?(:gemini, "gemini-3.5-flash-lite")
      refute Director.always_thinks?(:haiku, "claude-haiku-5-5")
      refute Director.always_thinks?(:openai, "gpt-6-luna")
      refute Director.always_thinks?(:gemma, "gemma4:12b-mlx")
    end
  end

  describe "the compose prompt's element length" do
    test "defaults to 4-12 words and follows DIRECTOR_ELEMENT_WORDS" do
      with_env("DIRECTOR_ELEMENT_WORDS", nil, fn ->
        assert Director.element_words() == "4-12"
        [%{role: "system", content: prompt}] = Director.init_conversation(nil, prompt: :compose)
        assert prompt =~ "4-12 words, purely visual"
      end)

      with_env("DIRECTOR_ELEMENT_WORDS", "30-45", fn ->
        [%{role: "system", content: prompt}] = Director.init_conversation(nil, prompt: :compose)
        assert prompt =~ "30-45 words, purely visual"
        refute prompt =~ "4-12 words"
      end)
    end

    test "anything that is not min-max falls back rather than breaking the prompt" do
      with_env("DIRECTOR_ELEMENT_WORDS", "lots", fn ->
        assert Director.element_words() == "4-12"
        assert Director.element_words_upper() == 12
      end)
    end

    test "above 15 words the examples are written long and a rule says to use the whole length" do
      with_env("DIRECTOR_ELEMENT_WORDS", nil, fn ->
        [%{content: prompt}] = Director.init_conversation(nil, prompt: :compose)
        assert prompt =~ "NEW: a round yellow sun | POS: top"
        refute prompt =~ "hem flaring wide"
        refute prompt =~ "Use the WHOLE length"
      end)

      with_env("DIRECTOR_ELEMENT_WORDS", "30-45", fn ->
        assert Director.element_words_upper() == 45
        [%{content: prompt}] = Director.init_conversation(nil, prompt: :compose)
        assert prompt =~ "Use the WHOLE length: 30-45 words of concrete visual detail"
        assert prompt =~ "hem flaring wide"
        refute prompt =~ "NEW: a round yellow sun | POS: top"
        # Every long example really is long: the models copy what they see.
        [_, examples] = String.split(prompt, "EXAMPLES", parts: 2)
        elements = for [_, element] <- Regex.scan(~r/NEW: ([^|]+) \| POS/, examples), do: element
        assert length(elements) == 4
        for element <- elements, do: assert(length(String.split(element)) in 30..45)
      end)
    end

    test "the global prompt can be pinned too, whatever the image provider" do
      [%{role: "system", content: prompt}] = Director.init_conversation(nil, prompt: :global)
      assert prompt =~ "MOST RECENT scene elements"
    end
  end

  describe "configured_model/1 and timeout_ms/1" do
    test "name the model .env would run, per provider" do
      with_env("ANTHROPIC_MODEL", nil, fn ->
        assert Director.configured_model(:haiku) == "claude-haiku-4-5"
      end)

      with_env("ANTHROPIC_MODEL", "claude-haiku-5-5", fn ->
        assert Director.configured_model(:haiku) == "claude-haiku-5-5"
      end)

      with_env("OPENAI_MODEL", nil, fn ->
        assert Director.configured_model(:openai) == "gpt-6-luna"
      end)

      assert Director.timeout_ms(:gemma) > Director.timeout_ms(:gemini)
    end
  end

  describe "openai_base_url/0" do
    test "is OpenAI unless OPENAI_BASE_URL names a compatible endpoint" do
      with_env("OPENAI_BASE_URL", nil, fn ->
        assert Director.openai_base_url() == "https://api.openai.com/v1"
      end)

      with_env("OPENAI_BASE_URL", "http://127.0.0.1:8787/v1/", fn ->
        assert Director.openai_base_url() == "http://127.0.0.1:8787/v1"
      end)
    end
  end

  defp with_env(key, value, fun) do
    previous = System.get_env(key)
    if value, do: System.put_env(key, value), else: System.delete_env(key)

    try do
      fun.()
    after
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end
  end
end
