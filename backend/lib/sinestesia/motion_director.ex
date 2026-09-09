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
  You are the motion director of a live generative-art music show. The show
  is a chain of short video shots. Shot N OPENS on image N (already
  generated — its description is given) and must ARRIVE at image N+1 by its
  final frame; a video model renders each shot from your direction plus
  those two keyframes.

  For each shot, write ONE terse direction (max 30 words) for the video
  model: what moves, what the camera does, how the scene transforms toward
  the next image. Direct continuous, organic motion — drift, sway, flow,
  light change, growth — never hard cuts, never new subjects the two images
  don't contain. The LAST shot has no destination: let it live and slowly
  settle.

  You receive the show's visual style and the numbered image descriptions.
  Reply with ONLY the directions, one per line, in the form:

  N: direction

  exactly one line per shot, 0-indexed, no other text, no markdown.
  """

  @doc """
  One direction per scene, in order. `scene_prompts` are the image
  Director's prompts for the anchors, in reveal order.
  """
  @spec direct(String.t() | nil, [String.t()]) :: [String.t()]
  def direct(_style, []), do: []

  def direct(style, scene_prompts) do
    case call_gemini(user_message(style, scene_prompts)) do
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

  defp user_message(style, scene_prompts) do
    numbered =
      scene_prompts
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {p, i} -> "#{i}: #{p}" end)

    "STYLE: #{style || "unspecified"}\n\nIMAGES (numbered):\n#{numbered}"
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
          generationConfig: %{temperature: 0.2, maxOutputTokens: 4000}
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
