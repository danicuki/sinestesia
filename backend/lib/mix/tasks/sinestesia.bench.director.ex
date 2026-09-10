defmodule Mix.Tasks.Sinestesia.Bench.Director do
  @shortdoc "Latency × direction-length benchmark across director models"
  @moduledoc """
  How many words of direction can each model produce within a latency
  budget? Live, the Director's reply sits between a sung line and its
  picture, so its OUTPUT LENGTH is bounded by time, not taste — a slow
  model must speak in captions, a fast one can direct a whole shot. This
  benchmark measures it instead of guessing: for each model it requests
  directions at growing target lengths, times the full (non-streaming)
  completion the pipeline actually waits for, and reports words/second
  plus the longest direction that fits common budgets.

      mix sinestesia.bench.director
      mix sinestesia.bench.director --runs 3 --targets 15,30,60,100
      mix sinestesia.bench.director --models gemini:gemini-3.1-flash-lite

  Defaults: every model it has credentials for — the configured
  OLLAMA_MODEL, plus gemini flash-lite/flash when GOOGLE_API_KEY is set —
  at TWO target lengths, ONE run each (2 calls per model + 1 warmup per
  provider): a fixed-cost + per-word line needs exactly two points, and
  samples are someone's quota. `--runs`/`--targets` deepen the sweep.
  Nothing here is a paid video call — text only.
  """
  use Mix.Task

  # Two points per model by default — a fixed-cost + per-word line needs
  # exactly two, and every extra sample is real quota on someone's key
  # (founder: "Basta um ou dois"). --targets/--runs deepen it when wanted.
  @default_targets [20, 100]
  @budgets_ms [500, 1000, 2000]

  @line "Queria que a verdade fosse como um fruto, que a gente alcançasse a qualquer minuto"
  @context "A Brazilian song about longing; the film is a dusk-lit modernist landscape."

  @impl true
  def run(args) do
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

    models = parse_models(opts[:models]) || available_models()

    models == [] &&
      Mix.raise("no models available — set GOOGLE_API_KEY and/or run ollama, or pass --models")

    calls = length(models) * length(targets) * runs

    Mix.shell().info(
      "── director bench: #{length(models)} model(s) × #{length(targets)} lengths × #{runs} run(s) = #{calls} calls (+1 warmup per provider) ──\n"
    )

    # One untimed warmup per provider KIND: the first request pays TLS
    # setup (and ollama pays model load) — without this the fixed cost of
    # whichever model runs first is inflated by infrastructure.
    for kind <- models |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      {_kind, model} = Enum.find(models, &(elem(&1, 0) == kind))
      complete(kind, model, "Reply with the single word: ready", "warmup")
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

  # ── measurement ──────────────────────────────────────────────────────────

  defp time_completion(kind, model, target_words) do
    system =
      "You are the film director of a music video. For the sung line you receive, " <>
        "write ONE cinematic scene direction of about #{target_words} words — subject, " <>
        "action, camera, light. Reply with ONLY the direction, no preamble."

    user = "#{@context}\nSung line: \"#{@line}\""

    started = System.monotonic_time(:millisecond)

    case complete(kind, model, system, user) do
      {:ok, text} -> {System.monotonic_time(:millisecond) - started, text}
      {:error, reason} ->
        Mix.shell().error("  #{model}: #{inspect(reason)}")
        {nil, ""}
    end
  end

  defp complete(:gemini, model, system, user), do: gemini_call(model, system, user, true)

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

    url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

    case Req.post(url, json: body, receive_timeout: 60_000, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        case get_in(body, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) do
          text when is_binary(text) -> {:ok, text}
          _ -> {:error, {:empty, body["promptFeedback"]}}
        end

      {:ok, %{status: 400, body: body}} ->
        message = get_in(body, ["error", "message"]) || inspect(body)

        if thinking_off? and message =~ ~r/think/i do
          Mix.shell().info("  (#{model} refuses thinkingBudget 0 — measuring WITH thinking)")
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

  defp complete(:ollama, model, system, user) do
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

  # ── roster ───────────────────────────────────────────────────────────────

  defp parse_models(nil), do: nil

  defp parse_models(spec) do
    for entry <- String.split(spec, ","), entry != "" do
      case String.split(String.trim(entry), ":", parts: 2) do
        ["gemini", model] -> {:gemini, model}
        ["ollama", model] -> {:ollama, model}
        _ -> Mix.raise("model spec must be gemini:<id> or ollama:<id>, got #{entry}")
      end
    end
  end

  defp available_models do
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

  # ── reporting ────────────────────────────────────────────────────────────

  defp print_model(kind, model, rows) do
    Mix.shell().info("#{kind}:#{model}")
    Mix.shell().info("  target   median     words   words/s")

    for %{target: t, ms: ms, words: w} <- rows do
      if ms do
        wps = if ms > 0, do: Float.round(w * 1000 / ms, 1), else: 0.0

        Mix.shell().info(
          "  #{pad(t, 5)}w  #{pad(ms, 6)}ms  #{pad(w, 6)}w  #{pad(wps, 7)}"
        )
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
    Mix.shell().info("  model" <> String.duplicate(" ", 34) <> Enum.map_join(@budgets_ms, "  ", &"#{pad(&1, 6)}ms"))

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

    Mix.shell().info("\n(words within budget ≈ (budget - fixed cost) × words/sec; capped at 200w)")
  end

  defp median(list) do
    sorted = Enum.sort(list)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp word_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()

  defp pad(v, n), do: v |> to_string() |> String.pad_leading(n)
end
