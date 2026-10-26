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

    %{
      variant: variant,
      provider: first(rows, "provider"),
      model: first(rows, "model"),
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
          "#{percent(c.valid)} | #{percent(c.atmos)} | #{c.pos_repeats} | #{int(c.element_words)} | " <>
          "#{int(c.out_tokens)} | #{int(c.thinking_tokens)} | #{c.cut} | #{int(c.decode_tps)} | " <>
          "#{usd(c.cost_per_show, c.provider)} | #{measured(c)} |"
      end)

    legend =
      Enum.map_join(cards, "\n", fn c ->
        # Rows keep the accepted setting as `inspect/1` text; "nil" is "no field sent".
        thinking =
          case Enum.reject(c.thinking, &(&1 == "nil")) do
            [] -> "no thinking field sent"
            cfgs -> "thinking #{Enum.join(cfgs, " / ")}"
          end

        "- **#{c.variant}** — DIRECTOR_PROVIDER=#{c.provider}, model `#{c.model}`, #{thinking}; " <>
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

    **p50 / p95** = ms from sending the sung line to the reply in hand: the full
    non-streaming round trip the pipeline waits for before it can ask for a picture,
    over every turn. **Over budget** = share of turns slower than the provider's live
    timeout (3 s cloud, 8 s Ollama), where the chain would have moved on without the
    reply. **Format** = replies that are exactly `NEW: … | POS: <place>` or `ATMOS: …`;
    anything else reaches the image model as a salvaged fragment. **ATMOS** = share of
    well-formed replies that chose an atmospheric shift over a new element. **POS
    repeats** = consecutive elements placed at the same position, which the prompt
    forbids. **Words/element** = median length of a `NEW:` element. **Out / thinking
    tok** = median output tokens billed per turn, and how many of them were reasoning
    where the API says. **Cut** = replies the output cap truncated. **Local tok/s** =
    Ollama's own generation speed (prompt processing excluded). **$/show** = 15 songs ×
    40 lines at list price, no prompt caching, thinking billed as output. Sorted by p50.

    | model | p50 ms | p95 ms | over budget | format | ATMOS | POS repeats | words/element | out tok | thinking tok | cut | local tok/s | $/show | measured |
    |---|---|---|---|---|---|---|---|---|---|---|---|---|---|
    #{table}
    #{fresh}

    #{legend}
    #{if errors == "", do: "", else: "\n### Errors\n\n" <> errors <> "\n"}
    Latency is measured from the machine the task ran on (last column); cloud rows
    taken anywhere but the show machine measure someone else's network, and local
    rows measure that machine's GPU. Ollama's first turn of each song pays the whole
    system prompt (no prefix cache yet): first-turn p50 is in the details.

    ### Details

    | model | first turn p50 ms | in tok | out tok | thinking tok | errors |
    |---|---|---|---|---|---|
    #{Enum.map_join(cards, "\n", &"| #{&1.variant} | #{int(&1.first_turn_p50)} | #{int(&1.in_tokens)} | #{int(&1.out_tokens)} | #{int(&1.thinking_tokens)} | #{&1.errors} |")}
    """
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

  defp percent(nil), do: "—"
  defp percent(x), do: "#{round(x * 100)}%"

  defp usd(nil, provider) when provider in ["gemma", "zerog"], do: "0 (local)"
  defp usd(nil, _), do: "—"
  defp usd(x, _), do: "$#{:erlang.float_to_binary(x / 1, decimals: 2)}"

  defp measured(%{at: nil, host: host}), do: host
  defp measured(%{at: at, host: host}), do: String.slice(at, 0, 10) <> " " <> host
end
