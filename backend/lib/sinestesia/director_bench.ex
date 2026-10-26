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

    """
    ## Director bench — #{length(songs)} songs, #{turns} sung lines, elements of #{Enum.join(specs, " / ")} words

    ### In short

    #{verdict(cards, specs)}

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
  defp verdict([], _specs), do: "Nothing measured yet."

  defp verdict(cards, specs) do
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
