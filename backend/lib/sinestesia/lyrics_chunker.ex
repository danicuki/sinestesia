defmodule Sinestesia.LyricsChunker do
  @moduledoc """
  Splits a KNOWN song's full lyrics into a sequence of visually coherent
  "scene units" — the chunks the look-ahead machinery pre-renders and reveals
  one at a time — instead of every chunk being exactly one physical line.

  Why this exists: the pasted/imported lyrics' line breaks are a formatting
  artifact of wherever they came from (a site's own wrapping), not a
  musically or visually meaningful boundary. Gating the eager bootstrap and
  every subsequent look-ahead render on a FIXED unit — a word count, a line
  count, always-just-one-line — kept turning out wrong for real songs (see
  HANDOFF.md gotchas #29, #36, #37): sometimes one line is plenty ("Vai
  voando, contornando"), sometimes a single line is too thin to draw anything
  coherent from ("Numa folha qualquer" alone has no concrete imagery — the
  yellow sun is in the NEXT line). Since the whole song is already known the
  moment it's loaded, the right answer is to ask an LLM to read the WHOLE
  thing once and decide, and let a per-line default carry the show if that
  call is unavailable or fails — never to guess with a number.

  Runs ONCE per song, off the pipeline's critical path (a background Task,
  same shape as `Sinestesia.SongId`): the caller renders/reveals off the
  per-line fallback the instant lyrics load and only upgrades to the smarter
  chunking if/when this resolves before it matters.

  Deliberately a LITE model, unlike `Sinestesia.SongId`: naming a performed
  song needs real-world knowledge; splitting lyrics that are already fully in
  hand is pure text structuring and needs none. A non-lite model measured
  live spent its whole per-attempt timeout "thinking" before answering, so
  the call never once finished before falling back — silently defeating the
  entire feature. Kept as an env-overridable default rather than a hardcode
  in case a future model generation changes this tradeoff.
  """
  require Logger

  @type chunk :: %{start_line: non_neg_integer(), end_line: non_neg_integer(), text: String.t()}

  defp timeout_ms, do: String.to_integer(System.get_env("LYRICS_CHUNK_TIMEOUT_MS", "15000"))

  @attempts 2

  @system """
  You split a song's lyrics into a sequence of short VISUAL SCENE UNITS for a
  live generative-art performance. Each unit becomes exactly one prompt to an
  image-generating AI, revealed the moment the audience finishes singing it —
  so it must carry enough content to depict one coherent picture, but no more
  than that.

  A single short line is OFTEN already enough ("Vai voando, contornando").
  Only merge it with the line(s) after it when it is clearly incomplete
  without them — a sentence split across a line break with no punctuation to
  mark it, a dangling clause, an image that makes no sense alone (e.g. "Numa
  folha qualquer" needs "Eu desenho um sol amarelo" to mean anything visual).

  Favor SMALL units. The audience sees a new picture at the end of every
  unit, gated on that unit actually being sung — bigger units mean longer
  waits between pictures. Never invent a break in the middle of a sentence;
  never merge lines unless the earlier one genuinely cannot stand alone.

  You will receive the lyrics as numbered lines (0-indexed, one per line).
  Reply with ONLY a list of ranges, one per line, in the form:

  START-END

  covering EVERY line exactly once, in order, with no gaps and no overlaps.
  A single-line unit is written "START-START" (e.g. "0-0"). No other text,
  no commentary, no markdown fences.
  """

  @doc """
  Chunk a song's flat, normalized script (one string per line — see
  `Sinestesia.PerformanceFollower.normalize/1`) into scene units.

  Returns `{:ok, [chunk()]}` covering every line exactly once, in order, or
  `{:error, reason}` — the caller is expected to fall back to one chunk per
  line (see `fallback/1`), never to block waiting for this.
  """
  @spec chunk([String.t()]) :: {:ok, [chunk()]} | {:error, term()}
  def chunk([]), do: {:ok, []}

  def chunk(lines) when is_list(lines) do
    numbered =
      lines
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, i} -> "#{i}: #{line}" end)

    user = "LYRICS (numbered):\n#{numbered}"

    providers()
    |> Enum.reduce_while({:error, {:no_provider, []}}, fn provider, {:error, {_, failures}} ->
      case attempt(provider, user) do
        {:ok, raw} ->
          case parse(raw, length(lines)) do
            {:ok, ranges} ->
              {:halt, {:ok, to_chunks(ranges, lines)}}

            {:error, reason} ->
              Logger.warning(
                "[lyrics_chunker:#{provider}] bad response (#{inspect(reason)}); trying next"
              )

              {:cont, {:error, {:all_failed, failures ++ [{provider, reason}]}}}
          end

        {:error, reason} ->
          Logger.warning("[lyrics_chunker:#{provider}] #{inspect(reason)}; trying next")
          {:cont, {:error, {:all_failed, failures ++ [{provider, reason}]}}}
      end
    end)
  end

  def chunk(_), do: {:error, :invalid_script}

  @doc "One chunk per line — the safe default this feature must never regress below."
  @spec fallback([String.t()]) :: [chunk()]
  def fallback(lines) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, i} -> %{start_line: i, end_line: i, text: line} end)
  end

  # Same world-knowledge-first chain SongId uses. The local model is opt-in
  # (LYRICS_CHUNK_ALLOW_LOCAL=1, mirroring SONGID_ALLOW_LOCAL) rather than
  # excluded outright: a small local model errs confidently on "did this
  # sentence complete" judgment, BUT — unlike a song title — its answer here
  # is a strict line-range format that parse/2 validates for full contiguous
  # coverage, so a bad answer degrades to the one-line fallback, never to a
  # wrong result. On a fully-offline box (no Gemini/Anthropic keys at all,
  # e.g. `mix sinestesia.video` on a machine with only Ollama), the choice is
  # not "local vs. cloud" — it's "local vs. the per-line fallback this feature
  # exists to improve on".
  defp providers do
    if System.get_env("LYRICS_CHUNK_ALLOW_LOCAL") in ["1", "true"] do
      [:gemini, :haiku, :ollama]
    else
      [:gemini, :haiku]
    end
  end

  defp attempt(provider, user, tries \\ @attempts) do
    case call(provider, user) do
      {:error, %Req.TransportError{reason: reason}} when tries > 1 ->
        Logger.debug("[lyrics_chunker:#{provider}] #{inspect(reason)}; retrying")
        attempt(provider, user, tries - 1)

      result ->
        result
    end
  end

  defp call(:gemini, user) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :google_api_key) do
      key when is_binary(key) and key != "" ->
        model = System.get_env("LYRICS_CHUNK_GEMINI_MODEL", "gemini-3.5-flash-lite")

        url =
          "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

        body = %{
          systemInstruction: %{parts: [%{text: @system}]},
          contents: [%{role: "user", parts: [%{text: user}]}],
          generationConfig: %{temperature: 0.0, maxOutputTokens: 2000}
        }

        case Req.post(url, json: body, receive_timeout: timeout_ms(), retry: false) do
          {:ok, %{status: 200, body: body}} ->
            case first_text(body) do
              nil -> {:error, {:empty_response, finish_reason(body)}}
              t -> {:ok, t}
            end

          {:ok, resp} ->
            {:error, {:bad_status, resp.status}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :no_key}
    end
  end

  defp call(:haiku, user) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :anthropic_api_key) do
      key when is_binary(key) and key != "" ->
        body = %{
          model: System.get_env("LYRICS_CHUNK_ANTHROPIC_MODEL", "claude-haiku-4-5"),
          max_tokens: 2000,
          system: @system,
          messages: [%{role: "user", content: user}]
        }

        headers = [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}]

        case Req.post("https://api.anthropic.com/v1/messages",
               json: body,
               headers: headers,
               receive_timeout: timeout_ms(),
               retry: false
             ) do
          {:ok, %{status: 200, body: %{"content" => [%{"text" => t} | _]}}} when is_binary(t) ->
            {:ok, t}

          {:ok, resp} ->
            {:error, {:bad_status, resp.status}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :no_key}
    end
  end

  # Mirrors SongId's ollama call: same endpoint, deterministic, no thinking.
  # num_predict is sized for the answer format (one "N-M" range per line —
  # a 60-line song needs ~400 tokens, nowhere near a prose budget).
  defp call(:ollama, user) do
    cfg = Application.fetch_env!(:sinestesia, :config)
    url = Keyword.fetch!(cfg, :ollama_url) <> "/api/chat"

    body = %{
      model: Keyword.fetch!(cfg, :ollama_model),
      stream: false,
      think: false,
      options: %{temperature: 0.0, num_predict: 1_000},
      messages: [
        %{role: "system", content: @system},
        %{role: "user", content: user}
      ]
    }

    case Req.post(url, json: body, receive_timeout: timeout_ms(), retry: false) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => t}}}} when is_binary(t) ->
        {:ok, t}

      {:ok, resp} -> {:error, {:bad_status, resp.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_text(%{"candidates" => [%{"content" => content} | _]}) do
    content
    |> Map.get("parts", [])
    |> Enum.find_value(fn
      %{"text" => t} when is_binary(t) -> if String.trim(t) == "", do: nil, else: t
      _ -> nil
    end)
  end

  defp first_text(_), do: nil

  defp finish_reason(%{"candidates" => [%{"finishReason" => r} | _]}), do: r
  defp finish_reason(_), do: :unknown

  # Parse "START-END" lines, tolerating stray blank lines/markdown fences, and
  # validate the ranges are contiguous, gapless, non-overlapping, and cover
  # exactly [0, line_count - 1] — anything else is treated as a bad response
  # (the caller falls back to one chunk per line) rather than trusted partway.
  defp parse(raw, line_count) do
    ranges =
      raw
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "```")))
      |> Enum.map(&parse_range/1)

    cond do
      Enum.any?(ranges, &(&1 == :error)) ->
        {:error, :unparseable}

      not contiguous?(ranges, line_count) ->
        {:error, {:bad_coverage, ranges}}

      true ->
        {:ok, ranges}
    end
  end

  defp parse_range(line) do
    case String.split(line, "-", parts: 2) do
      [s, e] ->
        with {start_line, ""} <- Integer.parse(String.trim(s)),
             {end_line, ""} <- Integer.parse(String.trim(e)),
             true <- end_line >= start_line do
          {start_line, end_line}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp contiguous?([], 0), do: true
  defp contiguous?([], _line_count), do: false

  defp contiguous?(ranges, line_count) do
    ranges
    |> Enum.reduce_while(0, fn {start_line, end_line}, expected ->
      if start_line == expected, do: {:cont, end_line + 1}, else: {:halt, :bad}
    end)
    |> case do
      :bad -> false
      next -> next == line_count
    end
  end

  defp to_chunks(ranges, lines) do
    Enum.map(ranges, fn {start_line, end_line} ->
      text = lines |> Enum.slice(start_line..end_line) |> Enum.join(" ")
      %{start_line: start_line, end_line: end_line, text: text}
    end)
  end
end
