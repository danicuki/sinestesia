defmodule Sinestesia.MotionDirector do
  @moduledoc """
  The Director for LIVING scenes. The image Director decides what each
  scene's picture IS; this one decides what the picture DOES — how scene N
  breathes, moves, and evolves until it becomes, exactly, scene N+1's image.

  Motion mode's clips are keyframed (first frame = anchor N, final frame =
  anchor N+1), so the video model already knows where the shot starts and
  ends. What it cannot know is HOW to travel: does the camera push in, do
  the leaves carry the change, does the light do the work? That's direction,
  and it benefits from seeing the WHOLE song at once — one call, after the
  anchors exist, off any latency path (this runs at composition time, never
  during a live show).

  Same posture as `Sinestesia.LyricsChunker`: a lite model, a strict output
  contract (one numbered line per scene, validated by count), and a
  serviceable generic fallback — a bad answer degrades, it never blocks.
  """
  require Logger

  @system """
  You are the film director of a continuous one-shot music video. The film
  is a chain of short generated shots: each shot's FIRST frame is the
  previous shot's LAST frame (the video model receives that frame plus your
  direction), so the whole song must read as ONE unbroken take — no cuts,
  no teleports, every change arrives by motion, transformation, camera
  movement or light.

  FIRST, interpret the SONG — read the whole lyric before directing a
  single shot, and invent the film's TREATMENT: one world, one
  protagonist or point of view, one palette and mood, one system of
  images that carries what the song MEANS. When the lyrics are
  metaphorical or abstract, film the feeling — the longing, the memory,
  the person being sung to — inside that world; NEVER illustrate the
  metaphor's noun ("wishing truth were a fruit" is not a picture of
  fruit — it is the protagonist reaching for something in the film's own
  language; "sweet" is not honey). Literal staging of figurative lines
  reads as comedy and kills the art. A song that is genuinely concrete
  and visual may be filmed as written.

  You receive the song's full lyrics, the visual style, and the numbered
  scenes: each scene is what is being SUNG during that shot, with a content
  note of what the scene should contain — treat the note as raw material,
  subordinate to your treatment, not as an order. Write ONE direction per
  shot, 50-90 words, cinematic and concrete, for a video generation model.
  This film renders OFFLINE — there is no latency budget, and video models
  reward generous detail, so spend words on:

  - SUBJECT and ACTION: what is on screen and what it does — real movement
    (walking, blooming, waves rolling), not a static tableau.
  - CAMERA: how the shot moves (push in, drift left, crane up, orbit...)
    — vary it across the song; a static camera is a wasted shot.
  - TRANSFORMATION: how this shot grows out of the inherited first frame
    and travels toward the next scene's world — morph, reveal, ride the
    motion; never cut.
  - LIGHT and MOOD: tied to what the lyric FEELS like at that moment; let
    choruses return with echoed imagery and verses evolve.
  - TEXTURE and DETAIL: surfaces, weather, particles, depth of field — the
    concrete sensory specifics that make a generated shot feel authored.

  The LAST shot has no destination: let it live, then slowly settle.

  NEVER name a real person in a direction — not celebrities, not the
  artist whose style is referenced (video models refuse real people's
  names and likenesses outright, and one refused shot is a hole in the
  film). When the style cites an artist, describe the LOOK in plain
  visual terms — brushwork, palette, shapes — without the name.

  Reply with the treatment first, then the directions, one per line:

  FILM: <one sentence — the world, protagonist/POV, palette, mood>
  N: direction

  exactly one FILM line and one direction line per shot, 0-indexed, no
  other text, no markdown.
  """

  @doc """
  One direction per scene, in order. `scene_prompts` are the pipeline
  Director's content notes per scene, in reveal order; `lyrics` is the full
  lyric sheet, given whole so the direction can breathe with the SONG —
  choruses echoing, verses evolving — not just with isolated captions.

  Returns `{:directed | :fallback, film, directions}` — `film` is the
  director's one-line treatment (nil on fallback), which callers prepend
  to every clip prompt so the world stays coherent even when a chain link
  breaks. The source tag exists because degrading silently once cost a
  whole render its expressiveness.
  """
  @attempts 3

  @default_model "gemini-3.5-flash-lite"

  @doc """
  Bump when the direction CONTRACT changes (word budget, treatment, system
  prompt shape) — it feeds the caller's cache fingerprint, so stale
  directions from an older contract are never silently served.
  """
  def revision, do: "v4-rich"

  def default_model, do: @default_model

  @spec direct(String.t() | nil, [String.t()], String.t() | nil, keyword()) ::
          {:directed | :fallback, String.t() | nil, [String.t()]}
  def direct(style, scene_prompts, lyrics \\ nil, opts \\ [])

  def direct(_style, [], _lyrics, _opts), do: {:directed, nil, []}

  def direct(style, scene_prompts, lyrics, opts) do
    model = Keyword.get(opts, :model, @default_model)
    user = user_message(style, scene_prompts, lyrics)

    case try_direct(user, model, length(scene_prompts), 2) do
      {:ok, film, directions} ->
        {:directed, film, directions}

      {:error, reason} ->
        Logger.warning("[motion_director] #{inspect(reason)}; using fallback")
        {:fallback, nil, fallback(scene_prompts)}
    end
  end

  # A miscounted or truncated answer (a real run lost scene 17 of 18 and
  # paid the fallback for it) gets one fresh roll before degrading — and
  # the finish reason is NAMED, so truncation (MAX_TOKENS) is
  # distinguishable from a model that simply lost count.
  defp try_direct(user, model, count, rolls) do
    case attempt(user, model, @attempts) do
      {:ok, raw, finish} ->
        case parse(raw, count) do
          {:ok, film, directions} ->
            {:ok, film, directions}

          {:error, reason} when rolls > 1 ->
            Logger.warning(
              "[motion_director] bad response (#{inspect(reason)}, finish: #{finish}); rerolling"
            )

            try_direct(user, model, count, rolls - 1)

          {:error, reason} ->
            {:error, {:bad_response, reason, finish}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A run sits at the cost-confirmation prompt for as long as the operator
  # thinks; the pool's keepalive dies exactly then, so the FIRST call after
  # a pause fails with :closed — hit live 2026-09-09. Transient failures
  # get retried before anything is allowed to degrade a paid render.
  defp attempt(user, model, tries) do
    case call_gemini(user, model) do
      {:error, reason} when tries > 1 ->
        if transient?(reason) do
          Logger.info("[motion_director] #{inspect(reason)}; retrying")
          Process.sleep(700)
          attempt(user, model, tries - 1)
        else
          {:error, reason}
        end

      result ->
        result
    end
  end

  defp transient?(%Req.TransportError{}), do: true
  defp transient?({:bad_status, s}) when s in [429, 500, 502, 503, 504], do: true
  defp transient?(_), do: false

  @doc """
  The no-LLM direction: gentle continuous motion toward the next anchor.
  Serviceable because the keyframes already carry the composition — this
  only loses the tailored camera/action language.
  """
  @spec fallback([String.t()]) :: [String.t()]
  def fallback(scene_prompts) do
    scene_prompts
    |> Enum.with_index()
    |> Enum.map(fn {_prompt, i} ->
      case Enum.at(scene_prompts, i + 1) do
        nil ->
          "the scene lives on with slow, dreamlike motion, gently settling"

        next ->
          "gentle continuous motion, the scene gradually transforming into: #{next}"
      end
    end)
  end

  defp user_message(style, scene_prompts, lyrics) do
    numbered =
      scene_prompts
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {p, i} -> "#{i}: #{p}" end)

    lyrics_block = if lyrics, do: "LYRICS:\n#{lyrics}\n\n", else: ""

    "STYLE: #{style || "unspecified"}\n\n#{lyrics_block}SCENES (numbered):\n#{numbered}"
  end

  # One numbered direction per scene, tolerating stray blank lines. Anything
  # short of exact coverage is a bad answer — the fallback is always safe.
  @doc false
  def parse(raw, count) do
    trimmed =
      raw
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "```")))

    # The treatment line is the film's identity; a model that skipped it
    # still yields a usable answer (film nil), never a rejection — the
    # numbered contract below stays the strict part.
    {film, rest} =
      case trimmed do
        ["FILM:" <> film | rest] -> {String.trim(film), rest}
        rest -> {nil, rest}
      end

    lines =
      Enum.map(rest, fn line ->
        case Regex.run(~r/^(\d+)\s*[:.\-]\s*(.+)$/, line) do
          [_, n, text] -> {String.to_integer(n), text}
          _ -> :error
        end
      end)

    cond do
      Enum.any?(lines, &(&1 == :error)) ->
        {:error, :unparseable}

      Enum.map(lines, &elem(&1, 0)) != Enum.to_list(0..(count - 1)) ->
        {:error, {:bad_coverage, Enum.map(lines, &elem(&1, 0))}}

      true ->
        {:ok, film, Enum.map(lines, &elem(&1, 1))}
    end
  end

  defp call_gemini(user, model) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :google_api_key) do
      key when is_binary(key) and key != "" ->
        url =
          "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

        body = %{
          systemInstruction: %{parts: [%{text: @system}]},
          contents: [%{role: "user", parts: [%{text: user}]}],
          # 50-90 words × up to ~50 scenes needs room; richness is the
          # entire point of this director.
          generationConfig: %{temperature: 0.3, maxOutputTokens: 16_000}
        }

        case Req.post(url, json: body, receive_timeout: 30_000, retry: false) do
          {:ok, %{status: 200, body: body}} ->
            case first_text(body) do
              nil -> {:error, :empty_response}
              t -> {:ok, t, finish_reason(body)}
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
  defp finish_reason(_), do: nil
end
