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

  You receive the song's full lyrics, the visual style, and the numbered
  scenes: each scene is what is being SUNG during that shot, with a content
  note of what the scene should contain. Write ONE direction per shot,
  30-60 words, cinematic and concrete, for a video generation model:

  - SUBJECT and ACTION: what is on screen and what it does — real movement
    (walking, blooming, waves rolling), not a static tableau.
  - CAMERA: how the shot moves (push in, drift left, crane up, orbit...)
    — vary it across the song; a static camera is a wasted shot.
  - TRANSFORMATION: how this shot grows out of the inherited first frame
    and travels toward the next scene's world — morph, reveal, ride the
    motion; never cut.
  - LIGHT and MOOD: tied to what the lyric FEELS like at that moment; let
    choruses return with echoed imagery and verses evolve.

  The LAST shot has no destination: let it live, then slowly settle.

  Reply with ONLY the directions, one per line, in the form:

  N: direction

  exactly one line per shot, 0-indexed, no other text, no markdown.
  """

  @doc """
  One direction per scene, in order. `scene_prompts` are the pipeline
  Director's content notes per scene, in reveal order; `lyrics` is the full
  lyric sheet, given whole so the direction can breathe with the SONG —
  choruses echoing, verses evolving — not just with isolated captions.
  """
  @spec direct(String.t() | nil, [String.t()], String.t() | nil) :: [String.t()]
  def direct(style, scene_prompts, lyrics \\ nil)

  def direct(_style, [], _lyrics), do: []

  def direct(style, scene_prompts, lyrics) do
    case call_gemini(user_message(style, scene_prompts, lyrics)) do
      {:ok, raw} ->
        case parse(raw, length(scene_prompts)) do
          {:ok, directions} ->
            directions

          {:error, reason} ->
            Logger.warning("[motion_director] bad response (#{inspect(reason)}); using fallback")
            fallback(scene_prompts)
        end

      {:error, reason} ->
        Logger.warning("[motion_director] #{inspect(reason)}; using fallback")
        fallback(scene_prompts)
    end
  end

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
    lines =
      raw
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "```")))
      |> Enum.map(fn line ->
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
        {:ok, Enum.map(lines, &elem(&1, 1))}
    end
  end

  defp call_gemini(user) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :google_api_key) do
      key when is_binary(key) and key != "" ->
        # A lite model on purpose (same lesson as LyricsChunker) — this is
        # text structuring over content already in hand. Hardcoded until the
        # feature earns a registry entry: it runs at composition time, where
        # a 30s budget makes model choice a taste call, not a latency one.
        model = "gemini-3.5-flash-lite"

        url =
          "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

        body = %{
          systemInstruction: %{parts: [%{text: @system}]},
          contents: [%{role: "user", parts: [%{text: user}]}],
          # 30-60 words × up to ~50 scenes needs room; richness is the
          # entire point of this director.
          generationConfig: %{temperature: 0.3, maxOutputTokens: 10_000}
        }

        case Req.post(url, json: body, receive_timeout: 30_000, retry: false) do
          {:ok, %{status: 200, body: body}} ->
            case first_text(body) do
              nil -> {:error, :empty_response}
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

  defp first_text(%{"candidates" => [%{"content" => content} | _]}) do
    content
    |> Map.get("parts", [])
    |> Enum.find_value(fn
      %{"text" => t} when is_binary(t) -> if String.trim(t) == "", do: nil, else: t
      _ -> nil
    end)
  end

  defp first_text(_), do: nil
end
