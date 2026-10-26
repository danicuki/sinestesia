defmodule Mix.Tasks.Sinestesia.Bench.Director do
  @shortdoc "Director shoot-out on real sung lines: latency × format × tokens × cost, per LLM"
  @moduledoc """
  Which LLM should direct the show? Two measurements, one task.

  ## `replay` (the default) — the live turn, model by model

  Replays real sung lines through the Director's OWN call
  (`Sinestesia.Director.complete/3`: the compose prompt, the output cap and the
  thinking switch the stage sends), one conversation per song the way a set
  runs, and scores every turn:

    * **latency** — the full non-streaming round trip the pipeline waits for,
      and how often it blows the provider's live budget (3 s cloud, 8 s Ollama);
    * **format** — did the reply honour `NEW: … | POS: …` / `ATMOS: …` exactly,
      how often it went ATMOS, how often it repeated the previous position;
    * **tokens** — in, out and thinking, from each API's own usage block; on
      Ollama also its prompt-processing / generation split and tok/s;
    * **cost** — per 90-minute show at list price.

      mix sinestesia.bench.director                  # every model there is a key for + the configured Ollama model
      mix sinestesia.bench.director --models anthropic:claude-haiku-5-5,gemini:gemini-3.5-flash-lite,gemma:gemma4:12b-mlx
      mix sinestesia.bench.director --words 30-45    # the "rich element" variant (DIRECTOR_ELEMENT_WORDS), cap raised to fit
      mix sinestesia.bench.director --songs dinda,pt-aquarela --lines 8
      mix sinestesia.bench.director --prompt global  # the whole-scene prompt Google/Pollinations get instead
      mix sinestesia.bench.director --report         # the scorecard over everything measured so far
      mix sinestesia.bench.director --dry-run

  Model specs are `provider:model`. Providers are the `DIRECTOR_PROVIDER`
  values — `gemma`, `gemini`, `haiku`, `openai`, `zerog` — and `ollama`,
  `google`, `anthropic` are accepted as the obvious aliases (the row still
  names the provider the way `.env` would).

  The corpus is what the Director really hears: the STT finals of the replay
  sessions in `tests/sessions/` (the duo's own takes), plus the reference lines
  of the STT bench corpus in `tests/stt/corpus/` when it has been prepared
  (pt/en/it/de). `--lines` (default 12) caps each song; a line sung twice is
  kept once so a chorus does not eat the budget.

  Results accumulate in `bench-director/`: `results/<variant>.json`, the
  `report.md` scorecard, and `replies.md` with every reply under its lyric for
  the duo to read side by side. Models can be measured on different days and
  machines — each row records when and on which host. A variant that already
  has rows for the selected lines is asked about before anything is sent
  (`--overwrite` / `--reuse` answer for all). Latency is measured from where
  the task runs, so cloud rows belong on the machine that will run the show
  and local rows on the machine that owns the GPU: the Mac, for both.

  Cost: a full default run is a few hundred short requests — cents at list
  price, Gemini 4 Argon the biggest single line.

  ## `lengths` — words of direction per latency budget

      mix sinestesia.bench.director lengths [--runs 3 --targets 15,30,60,100] [--models gemini:…,ollama:…]

  The older sweep for the video director: how many words of scene direction
  each model can produce within 0.5 / 1 / 2 s, fitted from two target lengths.
  """
  use Mix.Task
  require Logger

  alias Sinestesia.Director
  alias Sinestesia.DirectorBench

  @store "bench-director"
  @sessions "../tests/sessions"
  @stt_corpus "../tests/stt/corpus"
  @default_lines 12
  # Generous: the live budget is a column in the report, not a cut-off here —
  # a 6 s turn is a finding, a timed-out one is a hole.
  @bench_timeout_ms 60_000

  # What the show could switch to today, measured against what it runs.
  @default_cloud [
    {:gemini, "gemini-3.1-flash-lite"},
    {:gemini, "gemini-3.5-flash-lite"},
    {:gemini, "gemini-3.6-flash"},
    {:gemini, "gemini-4-argon"},
    {:haiku, "claude-haiku-4-5"},
    {:haiku, "claude-haiku-5-5"},
    {:haiku, "claude-sonnet-5-5"},
    {:openai, "gpt-6-luna"}
  ]

  @keys %{gemini: :google_api_key, haiku: :anthropic_api_key, openai: :openai_api_key}

  @impl true
  def run(args) do
    case args do
      ["lengths" | rest] -> lengths(rest)
      ["replay" | rest] -> replay(rest)
      _ -> replay(args)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # replay
  # ═══════════════════════════════════════════════════════════════════════════

  defp replay(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          models: :string,
          songs: :string,
          lines: :integer,
          words: :string,
          prompt: :string,
          report: :boolean,
          overwrite: :boolean,
          reuse: :boolean,
          dry_run: :boolean,
          verbose: :boolean
        ]
      )

    invalid != [] && Mix.raise("unknown option(s): #{inspect(invalid)}")

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:ssl, :req])
    unless opts[:verbose], do: Logger.configure(level: :warning)

    if opts[:report], do: finish([]), else: bench(opts)
  end

  defp bench(opts) do
    prompt = prompt_kind(opts[:prompt])
    words = opts[:words] || Director.default_element_words()

    Regex.match?(~r/\A\d+-\d+\z/, words) ||
      Mix.raise("--words wants min-max, e.g. 30-45 (got #{inspect(words)})")

    songs = corpus(opts)

    songs == [] &&
      Mix.raise(
        "no songs to replay — check --songs, or prepare tests/stt/corpus with mix sinestesia.bench.stt --prepare"
      )

    variants = roster(opts) |> Enum.map(&variant(&1, words, prompt))

    variants == [] &&
      Mix.raise("no models to run — no API key in .env and no Ollama; or pass --models")

    keys = MapSet.new(for s <- songs, i <- 0..(length(s.lines) - 1)//1, do: {s.id, i})
    {run, kept} = Enum.split_with(variants, &(decide(&1.id, keys, opts) == :run))

    kept != [] &&
      Mix.shell().info("   stored rows stand for: #{Enum.map_join(kept, ", ", & &1.id)}")

    turns = Enum.sum(Enum.map(songs, &length(&1.lines)))

    Mix.shell().info(
      "── director bench: #{length(songs)} songs, #{turns} lines × #{length(run)} models, elements of #{words} words, #{prompt} prompt → #{@store}/"
    )

    Enum.each(
      songs,
      &Mix.shell().info("   #{String.pad_trailing(&1.id, 14)} #{length(&1.lines)} lines")
    )

    Enum.each(
      run,
      &Mix.shell().info(
        "   #{&1.id}#{if &1.always_thinks, do: "  (reasons on every turn — cap #{&1.max_tokens})", else: ""}"
      )
    )

    Mix.shell().info("   ≈ #{estimate(run, turns)} at list price for the cloud rows")

    if opts[:dry_run], do: exit({:shutdown, 0})

    # The prompt reads the element length from the environment, like the stage.
    System.put_env("DIRECTOR_ELEMENT_WORDS", words)

    measured =
      Enum.flat_map(run, fn v ->
        case bench_variant(v, songs) do
          [] ->
            []

          rows ->
            # Stored as soon as it is measured: a later model failing costs nothing already paid for.
            rows = rows |> Jason.encode!() |> Jason.decode!()
            store_rows(v.id, rows)
            [v.id]
        end
      end)

    finish(measured)
  end

  defp prompt_kind(nil), do: :compose
  defp prompt_kind("compose"), do: :compose
  defp prompt_kind("global"), do: :global
  defp prompt_kind(other), do: Mix.raise("--prompt is compose or global, got #{inspect(other)}")

  # ── corpus ───────────────────────────────────────────────────────────────

  # Session finals first (the duo's own takes, what the pipeline really fed the
  # Director), then the STT bench references when prepared; ids as the files
  # name them. A line sung twice is kept once.
  defp corpus(opts) do
    sessions =
      for file <- Path.wildcard(Path.join(@sessions, "*.json")) do
        events = file |> File.read!() |> Jason.decode!() |> Map.get("events", [])

        lines =
          for %{"text" => t, "final" => true} <- events, String.trim(t) != "", do: String.trim(t)

        %{id: Path.basename(file, ".json"), lines: Enum.uniq(lines)}
      end

    refs =
      for file <- Path.wildcard(Path.join(@stt_corpus, "*.ref.txt")) do
        lines = file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
        %{id: Path.basename(file, ".ref.txt"), lines: Enum.uniq(lines)}
      end

    wanted = opts[:songs] && String.split(opts[:songs], ",", trim: true)
    cap = opts[:lines] || @default_lines

    (sessions ++ refs)
    |> Enum.filter(&(wanted == nil or &1.id in wanted))
    |> Enum.map(&%{&1 | lines: Enum.take(&1.lines, cap)})
    |> Enum.reject(&(&1.lines == []))
    |> tap(fn songs ->
      wanted &&
        Enum.each(
          wanted -- Enum.map(songs, & &1.id),
          &Mix.shell().error("   no song #{&1} in #{@sessions} or #{@stt_corpus}")
        )
    end)
  end

  # ── roster ───────────────────────────────────────────────────────────────

  defp roster(%{models: spec}) when is_binary(spec), do: parse_models(spec)

  defp roster(opts),
    do: if(opts[:models], do: parse_models(opts[:models]), else: default_roster())

  defp parse_models(spec) do
    for entry <- String.split(spec, ",", trim: true) do
      case String.split(String.trim(entry), ":", parts: 2) do
        [provider, model] when model != "" ->
          {provider_atom(provider, entry), model}

        _ ->
          Mix.raise(
            "model spec must be provider:model (e.g. anthropic:claude-haiku-5-5), got #{inspect(entry)}"
          )
      end
    end
  end

  defp provider_atom(p, entry) do
    case String.downcase(p) do
      g when g in ~w(gemma ollama local) ->
        :gemma

      g when g in ~w(gemini google) ->
        :gemini

      a when a in ~w(haiku anthropic claude) ->
        :haiku

      o when o in ~w(openai gpt) ->
        :openai

      z when z in ~w(zerog 0g) ->
        :zerog

      _ ->
        Mix.raise(
          "unknown provider in #{inspect(entry)} — gemma, gemini, haiku/anthropic, openai or zerog"
        )
    end
  end

  defp default_roster do
    cfg = Application.get_env(:sinestesia, :config, [])

    cloud =
      Enum.filter(@default_cloud, fn {provider, _} ->
        key = Keyword.get(cfg, @keys[provider])
        is_binary(key) and key != ""
      end)

    for {provider, key} <- @keys, not Enum.any?(cloud, &(elem(&1, 0) == provider)) do
      Mix.shell().info(
        "(#{key |> to_string() |> String.upcase()} unset — skipping #{provider} models)"
      )
    end

    cloud ++ local_roster(cfg)
  end

  # The configured Ollama model when it is actually pulled; the rest of what is
  # installed is named so it can be added with --models.
  defp local_roster(cfg) do
    url = Keyword.get(cfg, :ollama_url, "http://localhost:11434")
    want = Keyword.get(cfg, :ollama_model)

    case Req.get(url <> "/api/tags", receive_timeout: 2_000, retry: false) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        installed = Enum.map(models, & &1["name"])

        if want in installed do
          others = installed -- [want]

          others != [] &&
            Mix.shell().info(
              "(ollama also has #{Enum.join(others, ", ")} — add with --models gemma:<name>)"
            )

          [{:gemma, want}]
        else
          Mix.shell().info(
            "(OLLAMA_MODEL=#{want} is not pulled — skipping local; installed: #{Enum.join(installed, ", ")})"
          )

          []
        end

      _ ->
        Mix.shell().info("(ollama unreachable at #{url} — skipping local models)")
        []
    end
  end

  # Thinking models need room for the thinking (it counts against the cap);
  # a longer element needs room for the element. Otherwise the stage's cap.
  defp variant({provider, model}, words, prompt) do
    always = Director.always_thinks?(provider, model)
    [_, upper] = words |> String.split("-") |> Enum.map(&String.to_integer/1)

    max_tokens =
      cond do
        always -> 4_000
        words == Director.default_element_words() -> nil
        true -> 100 + upper * 3
      end

    id =
      "#{label(provider)}:#{model}" <>
        if(words == Director.default_element_words(), do: "", else: "@#{words}") <>
        if(prompt == :compose, do: "", else: "+#{prompt}")

    %{
      id: id,
      provider: provider,
      model: model,
      words: words,
      prompt: prompt,
      max_tokens: max_tokens,
      always_thinks: always
    }
  end

  # The vendor, for reading; the row keeps the DIRECTOR_PROVIDER value.
  defp label(:haiku), do: "anthropic"
  defp label(other), do: to_string(other)

  # A rough bill before anything is sent: ~1,000 prompt tokens and ~60 output
  # tokens a turn, list price, no caching; models that reason add to it.
  defp estimate(variants, turns) do
    total =
      variants
      |> Enum.map(fn v ->
        case DirectorBench.price(v.model) do
          {per_in, per_out} -> turns * (1_000 * per_in + 60 * per_out) / 1_000_000
          nil -> 0.0
        end
      end)
      |> Enum.sum()

    "$#{:erlang.float_to_binary(total / 1, decimals: 2)}" <>
      if(Enum.any?(variants, & &1.always_thinks), do: " plus thinking tokens", else: "")
  end

  # ── one model over the corpus ────────────────────────────────────────────

  defp bench_variant(v, songs) do
    Mix.shell().info("\n── #{v.id}")

    call_opts =
      [model: v.model, timeout_ms: @bench_timeout_ms] ++
        if(v.max_tokens, do: [max_tokens: v.max_tokens], else: [])

    # One untimed warm-up: TLS, Ollama's model load and the thinking-switch
    # ladder are paid here, none of which a turn mid-song pays. A model that
    # cannot even say "ready" (no key, wrong name, no quota) is skipped whole
    # instead of failing forty times at the bench timeout.
    warm = [
      %{role: "system", content: "Reply with the single word: ready"},
      %{role: "user", content: "ready?"}
    ]

    case Director.complete(v.provider, warm, call_opts) do
      {:ok, _, meta} ->
        Mix.shell().info("   warm · thinking #{inspect(meta.thinking)} · #{meta.model}")

        Enum.flat_map(songs, fn song ->
          Mix.shell().info("   #{song.id}")
          replay_song(v, song, call_opts)
        end)

      {:error, reason} ->
        Mix.shell().error("   ✗ skipped: #{describe(reason)}")
        []
    end
  end

  defp replay_song(v, song, call_opts) do
    conversation = Director.init_conversation(nil, prompt: v.prompt)

    {rows, _conv, _prev} =
      song.lines
      |> Enum.with_index()
      |> Enum.reduce({[], conversation, nil}, fn {line, i}, {rows, conv, prev_pos} ->
        user = %{role: "user", content: line}
        started = System.monotonic_time(:millisecond)
        result = Director.complete(v.provider, conv ++ [user], call_opts)
        ms = System.monotonic_time(:millisecond) - started

        row = row(v, song, i, line, ms, result, prev_pos)

        Mix.shell().info(
          "     t#{String.pad_leading(to_string(i + 1), 2, "0")} #{String.pad_leading(to_string(ms), 6)} ms  " <>
            "#{String.pad_trailing(to_string(row.kind), 8)} #{String.slice(row.error || row.reply || "", 0, 90)}"
        )

        # Like the stage: the reply joins the conversation, a failure leaves it as it was.
        case result do
          {:ok, text, _} ->
            {[row | rows], conv ++ [user, %{role: "assistant", content: text}],
             row.pos || prev_pos}

          _ ->
            {[row | rows], conv, prev_pos}
        end
      end)

    Enum.reverse(rows)
  end

  defp row(v, song, i, line, ms, result, prev_pos) do
    base = %{
      variant: v.id,
      provider: to_string(v.provider),
      model: v.model,
      words_spec: v.words,
      prompt: to_string(v.prompt),
      song: song.id,
      turn: i,
      lyric: line,
      ms: ms,
      budget_ms: Director.timeout_ms(v.provider),
      over_budget: ms > Director.timeout_ms(v.provider),
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      host: host()
    }

    case result do
      {:ok, text, meta} ->
        scored = DirectorBench.score(text, v.prompt)

        Map.merge(base, %{
          reply: text,
          answered: meta.model,
          kind: scored.kind,
          element: scored.element,
          pos: scored.pos,
          repeat_pos: scored.pos != nil and scored.pos == prev_pos,
          words: scored.words,
          in_tokens: meta.in_tokens,
          out_tokens: meta.out_tokens,
          thinking_tokens: meta.thinking_tokens,
          finish: meta.finish,
          cut: to_string(meta.finish) in ~w(length MAX_TOKENS max_tokens),
          thinking: inspect(meta.thinking),
          prefill_ms: meta.prefill_ms,
          decode_ms: meta.decode_ms,
          error: nil
        })

      {:error, reason} ->
        Map.merge(base, %{
          reply: nil,
          kind: :error,
          pos: nil,
          repeat_pos: false,
          error: describe(reason)
        })
    end
  end

  # One line a person can read, whatever the failure's shape.
  defp describe({:bad_status, status, message}), do: "HTTP #{status}: #{message}"
  defp describe({:empty_response, why}), do: "empty reply (#{inspect(why)})"
  defp describe(:no_key), do: "no API key in .env"
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(other), do: other |> inspect() |> String.slice(0, 200)

  defp host do
    {:ok, h} = :inet.gethostname()
    to_string(h)
  end

  # ── the store: one file per variant, the report over all of them ─────────

  defp store_file(id), do: Path.join([@store, "results", safe(id) <> ".json"])
  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9._@+-]/, "_")
  defp cached_rows(id), do: read_json(store_file(id)) || []
  defp row_key(r), do: {r["song"], r["turn"]}

  # New rows replace stored ones for the same line; lines not in this run stay.
  defp store_rows(id, rows) do
    File.mkdir_p!(Path.dirname(store_file(id)))
    keys = MapSet.new(rows, &row_key/1)
    kept = Enum.reject(cached_rows(id), &(row_key(&1) in keys))
    File.write!(store_file(id), Jason.encode!(kept ++ rows, pretty: true))
  end

  defp load_store do
    [@store, "results", "*.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(&(read_json(&1) || []))
  end

  defp decide(id, keys, opts) do
    have = Enum.filter(cached_rows(id), &(row_key(&1) in keys))

    cond do
      have == [] ->
        :run

      opts[:overwrite] ->
        :run

      opts[:reuse] ->
        :reuse

      true ->
        at = have |> Enum.map(& &1["at"]) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
        host = have |> Enum.map(& &1["host"]) |> Enum.reject(&is_nil/1) |> List.first()

        where =
          [at && String.slice(at, 0, 16), host] |> Enum.reject(&is_nil/1) |> Enum.join(" on ")

        answer =
          case Mix.shell().prompt(
                 "   #{id}: #{length(have)} rows stored (#{where}). Re-run and overwrite? [y/N]"
               ) do
            s when is_binary(s) -> s |> String.trim() |> String.downcase()
            _ -> ""
          end

        if answer in ~w(y yes s sim), do: :run, else: :reuse
    end
  end

  defp finish(updated) do
    all = load_store()
    all == [] && Mix.raise("nothing measured yet in #{@store}/ — run the bench first")

    report = DirectorBench.report(all, updated)
    File.write!(Path.join(@store, "report.md"), report)
    File.write!(Path.join(@store, "replies.md"), DirectorBench.replies(all))
    Mix.shell().info("\n" <> report)
    Mix.shell().info("every reply, line by line: #{Path.join(@store, "replies.md")}")
  end

  defp read_json(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         do: data,
         else: (_ -> nil)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # lengths — the words-per-second sweep for the video director
  # ═══════════════════════════════════════════════════════════════════════════

  # Two points per model by default — a fixed-cost + per-word line needs
  # exactly two, and every extra sample is real quota on someone's key
  # (founder: "Basta um ou dois"). --targets/--runs deepen it when wanted.
  @default_targets [20, 100]
  @budgets_ms [500, 1000, 2000]

  @line "Queria que a verdade fosse como um fruto, que a gente alcançasse a qualquer minuto"
  @context "A Brazilian song about longing; the film is a dusk-lit modernist landscape."

  defp lengths(args) do
    {opts, [], []} =
      OptionParser.parse(args, strict: [models: :string, runs: :integer, targets: :string])

    System.put_env("PORT", System.get_env("REPLAY_PORT", "4999"))
    Mix.Task.run("app.start")

    runs = opts[:runs] || 1

    targets =
      case opts[:targets] do
        nil -> @default_targets
        spec -> spec |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))
      end

    models = lengths_models(opts[:models]) || lengths_available()

    models == [] &&
      Mix.raise("no models available — set GOOGLE_API_KEY and/or run ollama, or pass --models")

    calls = length(models) * length(targets) * runs

    Mix.shell().info(
      "── director lengths: #{length(models)} model(s) × #{length(targets)} lengths × #{runs} run(s) = #{calls} calls (+1 warmup per provider) ──\n"
    )

    # One untimed warmup per provider KIND: the first request pays TLS
    # setup (and ollama pays model load) — without this the fixed cost of
    # whichever model runs first is inflated by infrastructure.
    for kind <- models |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      {_kind, model} = Enum.find(models, &(elem(&1, 0) == kind))
      lengths_complete(kind, model, "Reply with the single word: ready", "warmup")
    end

    results =
      for {kind, model} <- models do
        rows =
          for target <- targets do
            samples =
              for _ <- 1..runs do
                {ms, text} = time_completion(kind, model, target)
                {ms, word_count(text)}
              end
              |> Enum.reject(fn {ms, _} -> ms == nil end)

            case samples do
              [] ->
                %{target: target, ms: nil, words: 0}

              samples ->
                %{
                  target: target,
                  ms: median(Enum.map(samples, &elem(&1, 0))),
                  words: median(Enum.map(samples, &elem(&1, 1)))
                }
            end
          end

        print_model(kind, model, rows)
        {kind, model, rows}
      end

    print_recommendations(results)
  end

  defp time_completion(kind, model, target_words) do
    system =
      "You are the film director of a music video. For the sung line you receive, " <>
        "write ONE cinematic scene direction of about #{target_words} words — subject, " <>
        "action, camera, light. Reply with ONLY the direction, no preamble."

    user = "#{@context}\nSung line: \"#{@line}\""

    started = System.monotonic_time(:millisecond)

    case lengths_complete(kind, model, system, user) do
      {:ok, text} ->
        {System.monotonic_time(:millisecond) - started, text}

      {:error, reason} ->
        Mix.shell().error("  #{model}: #{inspect(reason)}")
        {nil, ""}
    end
  end

  defp lengths_complete(:gemini, model, system, user), do: gemini_call(model, system, user, true)

  defp lengths_complete(:ollama, model, system, user) do
    url = System.get_env("OLLAMA_URL", "http://localhost:11434")

    # Mirrors the live Director's ollama call (/api/chat, think: false) —
    # the first bench draft used /api/generate without it and measured 44s
    # of hidden deliberation instead of the 1-2s the stage actually sees.
    body = %{
      model: model,
      messages: [%{role: "system", content: system}, %{role: "user", content: user}],
      stream: false,
      think: false,
      options: %{temperature: 0.3, num_predict: 1_000}
    }

    case Req.post(url <> "/api/chat", json: body, receive_timeout: 120_000, retry: false) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => text}}}} -> {:ok, text}
      {:ok, resp} -> {:error, {:bad_status, resp.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Mirrors the live Director's gemini call: thinking OFF — on stage the
  # model answers, it does not deliberate. Some models REFUSE a zero
  # thinking budget with a 400 whose message says so; those get one retry
  # with thinking left on, flagged in the log, so the row measures what
  # that model can actually do rather than failing eight times in a row.
  defp gemini_call(model, system, user, thinking_off?) do
    key = Application.fetch_env!(:sinestesia, :config)[:google_api_key]

    generation =
      %{temperature: 0.3, maxOutputTokens: 4_000}
      |> then(fn g ->
        if thinking_off?, do: Map.put(g, :thinkingConfig, %{thinkingBudget: 0}), else: g
      end)

    body = %{
      systemInstruction: %{parts: [%{text: system}]},
      contents: [%{role: "user", parts: [%{text: user}]}],
      generationConfig: generation
    }

    url =
      "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

    case Req.post(url, json: body, receive_timeout: 60_000, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        case get_in(body, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) do
          text when is_binary(text) -> {:ok, text}
          _ -> {:error, {:empty, body["promptFeedback"]}}
        end

      {:ok, %{status: 400, body: body}} ->
        message = get_in(body, ["error", "message"]) || inspect(body)

        # thinkingConfig is the only exotic thing in this request, and
        # models that reject it don't always say so (3.5-flash-lite answers
        # a generic "invalid argument") — so ANY 400 gets one retry without
        # it. That also mirrors production: the chunker and motion director
        # call these models with no thinkingConfig at all.
        if thinking_off? do
          Mix.shell().info("  (#{model} rejected thinkingConfig — measuring without it)")
          gemini_call(model, system, user, false)
        else
          {:error, {:bad_status, 400, String.slice(message, 0, 200)}}
        end

      {:ok, resp} ->
        message = get_in(resp.body, ["error", "message"]) || ""
        {:error, {:bad_status, resp.status, String.slice(message, 0, 200)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lengths_models(nil), do: nil

  defp lengths_models(spec) do
    for entry <- String.split(spec, ","), entry != "" do
      case String.split(String.trim(entry), ":", parts: 2) do
        ["gemini", model] -> {:gemini, model}
        ["ollama", model] -> {:ollama, model}
        _ -> Mix.raise("model spec must be gemini:<id> or ollama:<id>, got #{entry}")
      end
    end
  end

  defp lengths_available do
    gemini =
      case Application.fetch_env!(:sinestesia, :config)[:google_api_key] do
        key when is_binary(key) and key != "" ->
          [
            {:gemini, "gemini-3.1-flash-lite"},
            # The newer lite tier — already the LyricsChunker/MotionDirector
            # default, so its latency curve matters most.
            {:gemini, "gemini-3.5-flash-lite"},
            {:gemini, "gemini-3.6-flash"}
          ]

        _ ->
          Mix.shell().info("(GOOGLE_API_KEY unset — skipping gemini models)")
          []
      end

    ollama =
      case Req.get(System.get_env("OLLAMA_URL", "http://localhost:11434") <> "/api/tags",
             receive_timeout: 2_000,
             retry: false
           ) do
        {:ok, %{status: 200}} ->
          [{:ollama, System.get_env("OLLAMA_MODEL", "gemma4:12b-mlx")}]

        _ ->
          Mix.shell().info("(ollama unreachable — skipping local models)")
          []
      end

    gemini ++ ollama
  end

  defp print_model(kind, model, rows) do
    Mix.shell().info("#{kind}:#{model}")
    Mix.shell().info("  target   median     words   words/s")

    for %{target: t, ms: ms, words: w} <- rows do
      if ms do
        wps = if ms > 0, do: Float.round(w * 1000 / ms, 1), else: 0.0

        Mix.shell().info("  #{pad(t, 5)}w  #{pad(ms, 6)}ms  #{pad(w, 6)}w  #{pad(wps, 7)}")
      else
        Mix.shell().info("  #{pad(t, 5)}w  FAILED")
      end
    end

    Mix.shell().info("")
  end

  # The fixed cost (network + prefill) and the per-word cost both matter:
  # fit ms ≈ base + words/rate from the endpoints, then invert for each
  # budget. Cruder than a regression, honest enough for a sizing decision.
  defp print_recommendations(results) do
    Mix.shell().info("── recommended direction length per latency budget ──")

    Mix.shell().info(
      "  model" <>
        String.duplicate(" ", 34) <> Enum.map_join(@budgets_ms, "  ", &"#{pad(&1, 6)}ms")
    )

    for {kind, model, rows} <- results do
      ok = Enum.filter(rows, & &1.ms)

      recs =
        if length(ok) >= 2 do
          first = List.first(ok)
          last = List.last(ok)
          dw = max(last.words - first.words, 1)
          dms = max(last.ms - first.ms, 1)
          per_word = dms / dw
          base = max(first.ms - first.words * per_word, 0)

          Enum.map(@budgets_ms, fn budget ->
            if budget <= base, do: 0, else: trunc((budget - base) / per_word)
          end)
        else
          Enum.map(@budgets_ms, fn _ -> nil end)
        end

      cells =
        Enum.map_join(recs, "  ", fn
          nil -> "     ?"
          0 -> "  too slow" |> String.slice(0, 8)
          n -> pad(min(n, 200), 6) <> "w"
        end)

      name = String.pad_trailing("#{kind}:#{model}", 38)
      Mix.shell().info("  #{name}#{cells}")
    end

    Mix.shell().info(
      "\n(words within budget ≈ (budget - fixed cost) × words/sec; capped at 200w)"
    )
  end

  defp median(list) do
    sorted = Enum.sort(list)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp word_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()

  defp pad(v, n), do: v |> to_string() |> String.pad_leading(n)
end
