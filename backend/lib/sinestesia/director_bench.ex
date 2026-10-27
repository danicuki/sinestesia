defmodule Sinestesia.DirectorBench do
  @moduledoc """
  Scoring for `mix sinestesia.bench.director`: what one Director reply is
  worth, what a run cost, and the scorecard over many — kept out of the task so
  it can be tested without a model on the line.

  Rows are the task's per-turn records with string keys: they round-trip
  through JSON, because a run made on the Mac is read back wherever the report
  is written.
  """

  alias Sinestesia.Director

  # A show: 15 songs of ~40 sung lines, one Director turn each.
  @show_turns 600

  # Director latencies the length fit is inverted for: a frame within a second,
  # within two, and the cloud timeout.
  @length_targets_ms [1_000, 2_000, 3_000]

  # List prices, USD per million tokens, read on each vendor's pricing page on
  # 2026-10-24. Thinking tokens bill as output everywhere. The longest matching
  # prefix wins, so an OpenAI snapshot id ("gpt-6-luna-2026-05-18") prices as
  # its model. Gemini 4 Argon doubles to 4 / 20 on 2026-12-01.
  @prices [
    {"gemini-3.1-flash-lite", 0.25, 1.50},
    {"gemini-3.5-flash-lite", 0.30, 2.50},
    {"gemini-3.6-flash", 0.75, 3.75},
    {"gemini-3.8-flash", 0.75, 3.75},
    {"gemini-4-argon", 2.00, 10.00},
    {"claude-haiku-4-5", 1.00, 5.00},
    {"claude-haiku-5-5", 0.10, 0.50},
    {"claude-sonnet-5-5", 2.00, 10.00},
    {"claude-opus-5-5", 4.00, 20.00},
    {"gpt-6-luna", 0.10, 0.50},
    {"gpt-6.1-sol", 2.00, 10.00},
    {"gpt-6-astra", 10.00, 50.00}
  ]

  @doc "Turns in the show the cost column prices."
  def show_turns, do: @show_turns

  @doc "Latency targets the length fit answers for, in ms."
  def length_targets, do: @length_targets_ms

  @doc """
  List price for `model` as `{usd_per_million_in, usd_per_million_out}`, or
  nil when it has none we know (a local model, or one missing from the table).
  """
  def price(model) when is_binary(model) do
    @prices
    |> Enum.filter(fn {prefix, _, _} -> String.starts_with?(model, prefix) end)
    |> Enum.max_by(fn {prefix, _, _} -> byte_size(prefix) end, fn -> nil end)
    |> case do
      nil -> nil
      {_, per_in, per_out} -> {per_in, per_out}
    end
  end

  def price(_), do: nil

  @doc """
  Classifies one reply against the contract its prompt set.

  Compose: exactly `NEW: <element> | POS: <one of the nine places>` or
  `ATMOS: <shift>`, on one line. Anything else — `**NEW:**`, a missing POS, an
  invented position, a second line — is `:invalid`: `Director.parse_story/1`
  still salvages a fragment from it on stage, but the fragment is not what
  was asked for.

  Global: one line of at most 30 words.
  """
  def classify(reply, :compose) when is_binary(reply) do
    text = String.trim(reply)
    places = Enum.join(Director.placements(), "|")

    cond do
      Regex.match?(~r/\ANEW:\s*[^|\n]+?\s*\|\s*POS:\s*(?:#{places})\s*\z/i, text) -> :new
      Regex.match?(~r/\AATMOS:\s*[^|\n]+\z/i, text) -> :atmos
      true -> :invalid
    end
  end

  def classify(reply, :global) when is_binary(reply) do
    text = String.trim(reply)

    cond do
      text == "" or String.contains?(text, "\n") -> :invalid
      length(words(text)) > 30 -> :invalid
      true -> :scene
    end
  end

  @doc """
  What one reply says, for its row: kind, the element's text and position, and
  how many words the element (or, for a scene list, the whole reply) carries.
  """
  def score(reply, prompt_kind) do
    case {prompt_kind, classify(reply, prompt_kind)} do
      {:compose, :new} ->
        %{element: element, placement: pos} = Director.parse_story(reply)
        %{kind: :new, element: element, pos: pos, words: length(words(element))}

      {:compose, :atmos} ->
        %{text: text} = Director.parse_story(reply)
        %{kind: :atmos, element: text, pos: nil, words: length(words(text))}

      {:compose, :invalid} ->
        %{kind: :invalid, element: nil, pos: nil, words: length(words(reply))}

      {:global, kind} ->
        %{kind: kind, element: String.trim(reply), pos: nil, words: length(words(reply))}
    end
  end

  @doc "Words of a text, whitespace-separated."
  def words(text), do: String.split(text, ~r/\s+/, trim: true)

  @doc """
  What a show of `show_turns/0` Director turns would cost at list price, from
  the tokens the rows actually billed. No prompt caching is assumed — every
  vendor now discounts the repeated system prompt — so this is a ceiling.
  nil for a model without a price (local) or an API that reported no usage.
  """
  def cost_per_show(rows) do
    billed = Enum.filter(rows, &(is_integer(&1["in_tokens"]) and is_integer(&1["out_tokens"])))

    with [first | _] <- billed, {per_in, per_out} <- price(first["model"]) do
      per_turn =
        (mean(Enum.map(billed, & &1["in_tokens"])) * per_in +
           mean(Enum.map(billed, & &1["out_tokens"])) * per_out) / 1_000_000

      per_turn * @show_turns
    else
      _ -> nil
    end
  end

  @doc """
  How long an element each model can write within a latency target, fitted from
  every well-formed reply it gave across the element lengths measured:
  round trip ≈ base + tokens × ms_per_token, and tokens ≈ tok0 + words ×
  tokens_per_word, both least squares. Base is a turn with nothing to write
  (network and prompt processing); the slope is the model's real writing speed,
  which no cloud API reports. Needs replies at clearly different lengths — a
  token spread of 30 or more over at least 8 rows — so one `--words` spec rarely
  qualifies and `--words 4-12,30-45,80-120` does.

  One map per provider:model (and prompt), sorted by words within the first
  target; models without a fit are left out.
  """
  def length_fit(rows) do
    rows
    |> Enum.filter(&usable_for_fit?/1)
    |> Enum.group_by(&{&1["provider"], &1["model"], &1["prompt"]})
    |> Enum.map(fn {_key, rs} -> fit_model(rs) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&(-&1.words_in[hd(@length_targets_ms)]))
  end

  defp usable_for_fit?(r) do
    is_nil(r["error"]) and r["kind"] in ["new", "atmos", "scene"] and
      is_integer(r["out_tokens"]) and is_number(r["ms"]) and is_integer(r["words"]) and
      r["words"] > 0
  end

  defp fit_model(rs) do
    tokens = Enum.map(rs, & &1["out_tokens"])
    spread = Enum.max(tokens) - Enum.min(tokens)

    with true <- length(rs) >= 8 and spread >= 30,
         {base, per_token} when per_token > 0 <- fit(Enum.map(rs, &{&1["out_tokens"], &1["ms"]})),
         {tok0, per_word} when per_word > 0 <- fit(Enum.map(rs, &{&1["words"], &1["out_tokens"]})) do
      %{
        model: model_of(rs),
        rows: length(rs),
        specs: specs_of(rs),
        base_ms: max(base, 0.0),
        ms_per_token: per_token,
        tok_s: 1000 / per_token,
        tokens_per_word: per_word,
        words_in:
          for t <- @length_targets_ms, into: %{} do
            {t, words_within(t, base, per_token, tok0, per_word)}
          end
      }
    else
      _ -> nil
    end
  end

  # Models measured at several lengths whose replies did not spread: what was
  # asked against what came back, so the report can say why there is no fit.
  defp asked_vs_wrote(rows) do
    rows
    |> Enum.filter(&usable_for_fit?/1)
    |> Enum.group_by(&{&1["provider"], &1["model"], &1["prompt"]})
    |> Enum.map(fn {_key, rs} -> %{model: model_of(rs), specs: specs_of(rs)} end)
    |> Enum.filter(&(length(&1.specs) >= 2))
    |> Enum.sort_by(& &1.model)
  end

  # The variant without its length suffix: one line per model, not per spec.
  defp model_of(rs), do: rs |> hd() |> Map.fetch!("variant") |> String.replace(~r/@\d+-\d+/, "")

  # Per `--words` spec: the median round trip, and the median length of the
  # `NEW:` elements actually written (ATMOS shifts stay short by design).
  defp specs_of(rs) do
    rs
    |> Enum.group_by(& &1["words_spec"])
    |> Enum.map(fn {spec, srs} ->
      elements =
        case Enum.filter(srs, &(&1["kind"] == "new")) do
          [] -> srs
          new -> new
        end

      %{
        spec: spec,
        p50: pct(Enum.map(srs, & &1["ms"]), 50),
        words: pct(Enum.map(elements, & &1["words"]), 50),
        rows: length(srs)
      }
    end)
    |> Enum.sort_by(&upper(&1.spec))
  end

  # Words that fit in `target_ms` of round trip under the two fits; 0 when the
  # base alone is over the target.
  defp words_within(target_ms, base, per_token, tok0, per_word) do
    tokens = (target_ms - base) / per_token
    words = (tokens - tok0) / per_word
    if words < 0, do: 0, else: trunc(words)
  end

  @doc "Least-squares `{intercept, slope}` of y on x; nil without two distinct x."
  def fit(pairs) when length(pairs) < 2, do: nil

  def fit(pairs) do
    n = length(pairs)
    mx = Enum.sum(Enum.map(pairs, &elem(&1, 0))) / n
    my = Enum.sum(Enum.map(pairs, &elem(&1, 1))) / n
    sxx = Enum.sum(for {x, _} <- pairs, do: (x - mx) * (x - mx))

    if sxx == 0 do
      nil
    else
      slope = Enum.sum(for {x, y} <- pairs, do: (x - mx) * (y - my)) / sxx
      {my - slope * mx, slope}
    end
  end

  @doc "One scorecard line over a variant's rows."
  def summarize(variant, rows) do
    ok = Enum.reject(rows, & &1["error"])
    ms = Enum.map(ok, & &1["ms"])
    valid = Enum.filter(ok, &(&1["kind"] in ["new", "atmos", "scene"]))
    new = Enum.filter(ok, &(&1["kind"] == "new"))

    decode_tps =
      for r <- ok, is_number(r["decode_ms"]), r["decode_ms"] > 0, is_integer(r["out_tokens"]) do
        r["out_tokens"] * 1000 / r["decode_ms"]
      end

    thinking = for r <- ok, is_integer(r["thinking_tokens"]), do: r["thinking_tokens"]

    # Content per second of waiting — what a second buys the stage. Words are
    # vendor-neutral; tokens are each vendor's own count of the same reply.
    words_per_s =
      for r <- valid, is_integer(r["words"]), is_number(r["ms"]), r["ms"] > 0 do
        r["words"] * 1000 / r["ms"]
      end

    out_tps =
      for r <- ok, is_integer(r["out_tokens"]), is_number(r["ms"]), r["ms"] > 0 do
        r["out_tokens"] * 1000 / r["ms"]
      end

    %{
      variant: variant,
      provider: first(rows, "provider"),
      model: first(rows, "model"),
      endpoint: first(rows, "endpoint"),
      turns: length(rows),
      errors: length(rows) - length(ok),
      p50: pct(ms, 50),
      p95: pct(ms, 95),
      first_turn_p50: pct(for(r <- ok, r["turn"] == 0, do: r["ms"]), 50),
      over_budget: share(Enum.count(ok, & &1["over_budget"]), length(ok)),
      valid: share(length(valid), length(ok)),
      atmos: share(Enum.count(ok, &(&1["kind"] == "atmos")), length(valid)),
      pos_repeats: Enum.count(ok, & &1["repeat_pos"]),
      element_words: pct(Enum.map(new, & &1["words"]), 50),
      in_tokens: pct(ints(ok, "in_tokens"), 50),
      out_tokens: pct(ints(ok, "out_tokens"), 50),
      thinking_tokens: if(thinking == [], do: nil, else: pct(thinking, 50)),
      cut: Enum.count(ok, & &1["cut"]),
      decode_tps: pct(decode_tps, 50),
      words_per_s: pct(words_per_s, 50),
      out_tps: pct(out_tps, 50),
      cost_per_show: cost_per_show(ok),
      thinking: ok |> Enum.map(& &1["thinking"]) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      at: rows |> Enum.map(& &1["at"]) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
      host:
        rows |> Enum.map(& &1["host"]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.join("/"),
      error_messages: rows |> Enum.map(& &1["error"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }
  end

  @doc "The scorecard over every stored row, as markdown; `updated` variants are marked ✦."
  def report(rows, updated) do
    songs = rows |> Enum.map(& &1["song"]) |> Enum.uniq()
    turns = rows |> Enum.map(&{&1["song"], &1["turn"]}) |> Enum.uniq() |> length()
    specs = rows |> Enum.map(& &1["words_spec"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    cards =
      rows
      |> Enum.group_by(& &1["variant"])
      |> Enum.map(fn {variant, rs} -> summarize(variant, rs) end)
      |> Enum.sort_by(&(&1.p50 || 1.0e12))

    fits = length_fit(rows)
    mark = fn c -> if c.variant in updated, do: " ✦", else: "" end

    table =
      Enum.map_join(cards, "\n", fn c ->
        "| #{c.variant}#{mark.(c)} | #{int(c.p50)} | #{int(c.p95)} | #{percent(c.over_budget)} | " <>
          "#{percent(c.valid)} | #{percent(c.atmos)} | #{int(c.element_words)} | #{dec(c.words_per_s)} | " <>
          "#{dec(c.out_tps)} | #{usd(c.cost_per_show, c.provider)} | #{measured(c)} |"
      end)

    details =
      Enum.map_join(cards, "\n", fn c ->
        "| #{c.variant} | #{int(c.first_turn_p50)} | #{int(c.in_tokens)} | #{int(c.out_tokens)} | " <>
          "#{int(c.thinking_tokens)} | #{c.cut} | #{c.pos_repeats} | #{int(c.decode_tps)} | #{c.errors} |"
      end)

    legend =
      Enum.map_join(cards, "\n", fn c ->
        # Rows keep the accepted setting as `inspect/1` text; "nil" is "no field sent".
        thinking =
          case Enum.reject(c.thinking, &(&1 == "nil")) do
            [] -> "no thinking field sent"
            cfgs -> "thinking #{Enum.join(cfgs, " / ")}"
          end

        "- **#{c.variant}** — DIRECTOR_PROVIDER=#{c.provider}, model `#{c.model}`#{via(c)}, #{thinking}; " <>
          "#{c.turns} turns, #{c.errors} failed, input #{int(c.in_tokens)} tokens/turn at the median."
      end)

    errors =
      cards
      |> Enum.filter(&(&1.error_messages != []))
      |> Enum.map_join("\n", fn c ->
        "- #{c.variant}: #{c.errors} turn(s) — #{Enum.join(c.error_messages, "; ") |> String.slice(0, 300)}"
      end)

    fresh =
      if updated == [],
        do: "",
        else:
          "\n✦ measured in this run; the other rows are from the store (bench-director/results/)."

    lengths =
      case fits do
        [] ->
          case asked_vs_wrote(rows) do
            [] ->
              "One element length measured per model so far. Run `--words 4-12,30-45,80-120` " <>
                "(three lengths; the store keeps each apart) to fit how far each model can go within the budget."

            notes ->
              "Several lengths were measured, but no model's replies spread enough to fit " <>
                "(30 tokens apart over 8 or more well-formed rows):\n\n" <>
                Enum.map_join(notes, "\n", fn n ->
                  "- `#{n.model}`: asked " <>
                    Enum.map_join(n.specs, ", ", &"#{&1.spec} → wrote #{int(&1.words)}") <>
                    " words at the median"
                end) <>
                "\n\nModels follow the examples more than the number; the compose prompt shows long " <>
                "examples once the spec goes above 15 words. Rows measured before that count short."
          end

        fits ->
          header = Enum.map_join(@length_targets_ms, " | ", &"words in #{sec(&1)} s")

          lines =
            Enum.map_join(fits, "\n", fn f ->
              asked = Enum.map_join(f.specs, ", ", &"#{&1.spec} → #{int(&1.words)} (#{int(&1.p50)} ms)")
              cells = Enum.map_join(@length_targets_ms, " | ", &words_cell(f.words_in[&1]))

              "| #{f.model} | #{asked} | #{int(f.base_ms)} | #{int(f.tok_s)} | #{dec(f.tokens_per_word)} | #{cells} |"
            end)

          """
          Fitted from every well-formed reply of a model across the element lengths
          measured: round trip ≈ base + tokens × ms/token, least squares. **Base** is a
          turn with nothing to write — network and prompt processing. **tok/s** is the
          slope: the model's real writing speed, which no cloud API reports. **Words in
          N s** inverts the fit for a Director latency target. **Asked → wrote** is the
          `--words` spec against the median element actually written at it; models
          anchor on the prompt's short examples and under-deliver long requests.

          | model | asked → wrote (p50 ms) | base ms | tok/s | tok/word | #{header} |
          |---|---|---|---|---|#{String.duplicate("---|", length(@length_targets_ms))}
          #{lines}

          Two more caps apply before any of this: the image provider's prompt window
          (local SDXL reads ~77 CLIP tokens, so ~12-word elements once the scene is
          re-listed; fal Flux takes ~60–80 words; Nano Banana more), and whether a
          longer direction stays faithful to the lyric — the bench does not judge that
          yet; `replies.md` is where to read it.
          """
      end

    """
    ## Director bench — #{length(songs)} songs, #{turns} sung lines, elements of #{Enum.join(specs, " / ")} words

    ### In short

    #{verdict(cards, specs, fits)}

    ### Scorecard

    | model | p50 ms | p95 ms | over budget | format | ATMOS | words/element | words/s | out tok/s | $/show | measured |
    |---|---|---|---|---|---|---|---|---|---|---|
    #{table}
    #{fresh}
    Sorted by p50. The columns:

    - **p50 / p95 ms** — from sending the sung line to having the reply: the whole
      round trip the pipeline waits before it can ask for a picture. Half the turns
      were faster than p50, 95% faster than p95.
    - **over budget** — turns slower than the live timeout (3 s cloud, 8 s Ollama).
      On stage the chain moves on without those replies.
    - **format** — replies that are exactly `NEW: … | POS: <place>` or `ATMOS: …`.
      Anything else reaches the image model as a salvaged fragment.
    - **ATMOS** — of the well-formed replies, how many painted nothing new and only
      shifted the mood of the whole picture (`ATMOS:` instead of `NEW:`). The prompt
      allows it only for lines with nothing drawable. Every model saw the same lines,
      so a higher share is a more hesitant director, not a different song;
      `replies.md` shows which lines each model passed on.
    - **words/element** — median length of a `NEW:` element.
    - **words/s** — words of the reply per second of round trip: how much paintable
      content a second of waiting buys. The prompt caps the element length, so with
      short elements this mostly ranks waiting time; `--words 30-45` measures who
      writes long elements fastest.
    - **out tok/s** — output tokens billed per second of round trip, the same idea
      in each vendor's own tokens. Tokenizers differ (the same 8-word element is ~15
      tokens at Google and ~25 at Anthropic), so compare vendors on words/s.
    - **$/show** — #{@show_turns} turns (15 songs × 40 lines) at list price, no prompt
      caching, thinking billed as output. Local models cost GPU time only.
    - **measured** — when and where. Latency is that machine's network and GPU;
      cloud rows taken anywhere but the show machine measure someone else's network.

    What each row ran:

    #{legend}

    ### How long can an element be?

    #{lengths}
    #{if errors == "", do: "", else: "\n### Errors\n\n" <> errors <> "\n"}
    ### Details

    | model | first turn p50 ms | in tok | out tok | thinking tok | cut | POS repeats | local tok/s | errors |
    |---|---|---|---|---|---|---|---|---|
    #{details}

    - **first turn** — the first line of each song carries the whole system prompt;
      on Ollama without a prefix cache that is the slow turn.
    - **in / out / thinking tok** — median tokens billed per turn as each API reports
      them; thinking is how many of the output tokens were reasoning, where the API
      says so (blank = the API reported none).
    - **cut** — replies the output cap truncated. **POS repeats** — consecutive
      elements at the same position, which the prompt forbids.
    - **local tok/s** — Ollama's own generation speed, prompt processing excluded.
      Cloud APIs report nothing comparable; words/s above is the cross-vendor number.
    """
  end

  # The questions the table is there to answer, answered in sentences.
  defp verdict([], _specs, _fits), do: "Nothing measured yet."

  defp verdict(cards, specs, fits) do
    scored = Enum.filter(cards, &is_number(&1.p50))
    fastest = Enum.min_by(scored, & &1.p50, fn -> nil end)
    remote = Enum.reject(scored, &(&1.provider == "gemma"))
    fastest_remote = Enum.min_by(remote, & &1.p50, fn -> nil end)

    clean =
      scored
      |> Enum.filter(&((&1.valid || 0) >= 0.95 and (&1.over_budget || 0) == 0))
      |> Enum.min_by(& &1.p50, fn -> nil end)

    richest =
      scored |> Enum.filter(&is_number(&1.words_per_s)) |> Enum.max_by(& &1.words_per_s, fn -> nil end)

    priced = Enum.filter(scored, &is_number(&1.cost_per_show))
    late = scored |> Enum.filter(&((&1.over_budget || 0) > 0)) |> Enum.sort_by(& &1.over_budget, :desc)
    sloppy = scored |> Enum.filter(&((&1.valid || 1) < 0.95)) |> Enum.sort_by(& &1.valid)
    atmos = Enum.filter(scored, &is_number(&1.atmos))
    short? = Enum.all?(specs, &(upper(&1) <= 15))

    [
      fastest &&
        "**Fastest:** `#{fastest.variant}`, #{int(fastest.p50)} ms at the median" <>
          if(fastest.provider == "gemma", do: " (local)", else: "") <>
          "." <>
          if(fastest_remote && fastest_remote != fastest,
            do: " Fastest cloud model: `#{fastest_remote.variant}`, #{int(fastest_remote.p50)} ms.",
            else: ""
          ),
      case clean do
        nil -> "**No model** kept the format on ≥ 95% of replies while never missing the live budget."
        c -> "**Fastest that also kept the format (≥ 95%) and never missed the live budget:** `#{c.variant}`, #{int(c.p50)} ms."
      end,
      case late do
        [] ->
          "**Live budget:** every model answered every turn within it."

        cs ->
          "**Over the live budget:** " <>
            Enum.map_join(cs, ", ", &"`#{&1.variant}` on #{percent(&1.over_budget)} of turns (p95 #{int(&1.p95)} ms)") <>
            " — not usable live. Everyone else answered in time."
      end,
      case sloppy do
        [] ->
          "**Format:** every model kept it on at least 95% of replies."

        cs ->
          "**Off-format replies:** " <>
            Enum.map_join(cs, ", ", &"`#{&1.variant}` #{percent(1 - &1.valid)}") <>
            "; each one reaches the image model as a salvaged fragment. The rest kept the format on ≥ 95%."
      end,
      richest &&
        "**Most content per second of waiting:** `#{richest.variant}`, #{dec(richest.words_per_s)} words/s" <>
          if(richest.out_tps, do: " (#{dec(richest.out_tps)} out tok/s)", else: "") <>
          "." <>
          if(short?,
            do:
              " With elements capped at #{Enum.join(specs, " / ")} words every model writes about the same amount, " <>
                "so this ranks waiting time, not writing speed; `--words 30-45` measures who writes long elements fastest.",
            else: ""
          ),
      case priced do
        [] ->
          nil

        cs ->
          cheapest = Enum.min_by(cs, & &1.cost_per_show)
          dearest = Enum.max_by(cs, & &1.cost_per_show)

          "**Cheapest cloud model:** `#{cheapest.variant}`, #{usd(cheapest.cost_per_show, cheapest.provider)} a show" <>
            if(dearest != cheapest,
              do: "; the dearest, `#{dearest.variant}`, #{usd(dearest.cost_per_show, dearest.provider)}.",
              else: "."
            )
      end,
      case atmos do
        [] ->
          nil

        cs ->
          least = Enum.min_by(cs, & &1.atmos)
          most = Enum.max_by(cs, & &1.atmos)

          "**ATMOS** — lines answered with a mood shift instead of something new to paint — " <>
            if(least == most,
              do: "was #{percent(least.atmos)} for `#{least.variant}`.",
              else:
                "ranged from #{percent(least.atmos)} (`#{least.variant}`) to #{percent(most.atmos)} (`#{most.variant}`). " <>
                  "Same lines for every model, so the spread is each director's taste; `replies.md` shows which lines."
            )
      end,
      case fits do
        [] ->
          nil

        [best | _] ->
          t = hd(@length_targets_ms)

          case best.words_in[t] do
            0 ->
              "**Within #{sec(t)} s of round trip** no model has room to write anything: the base alone is longer."

            n ->
              "**Most words within #{sec(t)} s of round trip:** `#{best.model}`, about #{n} " <>
                "(base #{int(best.base_ms)} ms, writes ~#{int(best.tok_s)} tok/s). The fit is in \"How long can an element be?\"."
          end
      end
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.map_join("\n", &("- " <> &1))
  end

  @doc "Every reply, song by song and line by line, with each model's answer under the lyric."
  def replies(rows) do
    variants = rows |> Enum.map(& &1["variant"]) |> Enum.uniq() |> Enum.sort()

    body =
      rows
      |> Enum.group_by(& &1["song"])
      |> Enum.sort_by(fn {song, _} -> song end)
      |> Enum.map_join("\n", fn {song, rs} ->
        turns =
          rs
          |> Enum.group_by(& &1["turn"])
          |> Enum.sort_by(fn {t, _} -> t end)
          |> Enum.map_join("\n", fn {t, trs} ->
            lines =
              for v <- variants, r = Enum.find(trs, &(&1["variant"] == v)), r != nil do
                said =
                  case r["error"] do
                    nil -> r["reply"] |> to_string() |> String.replace(~r/\s*\n\s*/, " ⏎ ")
                    err -> "✗ " <> err
                  end

                "- `#{v}` — #{said} (#{int(r["ms"])} ms)"
              end

            "**#{song} · #{t + 1}** “#{hd(trs)["lyric"]}”\n" <> Enum.join(lines, "\n") <> "\n"
          end)

        "### #{song}\n\n" <> turns
      end)

    "## Director bench — every reply\n\nThe same sung lines, each model's direction underneath. " <>
      "Read them the way the audience would see them painted: is it what the line says, is it drawable, is it new?\n\n" <>
      body
  end

  # ── numbers ──────────────────────────────────────────────────────────────

  @doc "Nearest-rank percentile; nil of nothing."
  def pct([], _p), do: nil

  def pct(xs, p) do
    sorted = Enum.sort(xs)
    Enum.at(sorted, max(0, ceil(p / 100 * length(sorted)) - 1))
  end

  defp mean([]), do: 0
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp ints(rows, key), do: for(r <- rows, is_integer(r[key]), do: r[key])

  defp share(_n, 0), do: nil
  defp share(n, d), do: n / d

  defp first(rows, key), do: Enum.find_value(rows, & &1[key])

  defp int(nil), do: "—"
  defp int(x) when is_float(x), do: x |> round() |> Integer.to_string()
  defp int(x), do: to_string(x)

  defp dec(nil), do: "—"
  defp dec(x), do: :erlang.float_to_binary(x / 1, decimals: 1)

  defp sec(ms) when rem(ms, 1000) == 0, do: Integer.to_string(div(ms, 1000))
  defp sec(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1)

  # Beyond ~300 words no image prompt is listening.
  defp words_cell(0), do: "too slow"
  defp words_cell(n) when n > 300, do: "300+"
  defp words_cell(n), do: Integer.to_string(n)

  # The upper bound of a "min-max" words spec; anything else counts as short.
  defp upper(spec) do
    case Regex.run(~r/\A\d+-(\d+)\z/, to_string(spec)) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp percent(nil), do: "—"
  defp percent(x), do: "#{round(x * 100)}%"

  defp usd(nil, provider) when provider in ["gemma", "zerog"], do: "0 (local)"
  defp usd(nil, _), do: "—"
  defp usd(x, _), do: "$#{:erlang.float_to_binary(x / 1, decimals: 2)}"

  defp via(%{endpoint: nil}), do: ""
  defp via(%{endpoint: url}), do: " via #{url}"

  defp measured(%{at: nil, host: host}), do: host
  defp measured(%{at: at, host: host}), do: String.slice(at, 0, 10) <> " " <> host
end
