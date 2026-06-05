defmodule Sinestesia.StyleCurator do
  @moduledoc """
  Auto-picks a visual style for the current song after a few lyrics arrive.

  Called once per session (or once per song boundary). Reads the accumulated
  lyrics + expressive features and asks Gemma to pick ONE style from a curated
  palette. The result is fed into `Pipeline.set_style/2`, which resets the
  Director's conversation so the new style takes effect.

  We constrain the choice to a fixed palette to keep behavior predictable —
  free-form curation produces wild outputs that break the demo.
  """
  require Logger

  # Story-mode palette: all "drawable" / "accumulable" styles.
  # Each leaves enough negative space and line-quality that NEW elements can
  # be added on top via img2img without destroying what is already there.
  @palette [
    "loose ink sketch on aged paper, sparse hand-drawn linework, sepia tones",
    "crayon drawing on white paper, childlike, bright simple shapes",
    "graffiti marker on concrete wall, raw bold outlines, urban",
    "charcoal sketch on grey paper, soft smudges and hatching",
    "watercolor and ink, pale washes, hand-drawn outlines",
    "Brazilian cordel woodcut print, black and white, hatched linework"
  ]

  @system """
  You pick the visual ART STYLE for a Brazilian MPB song based on its lyrics, mood, and vocal feel.

  The visuals will be built up element-by-element on a single evolving drawing as the song is sung. The style must be a DRAWING / SKETCH style that leaves room to ADD new elements on top.

  Choose EXACTLY ONE style from this list (output one line, verbatim, no quotes, no preamble):

  #{Enum.map_join(@palette, "\n", &"- #{&1}")}

  Match the style to the SONG:
  - nostalgic, intimate, melancholic, slow → loose ink sketch
  - playful, joyful, childlike, simple → crayon drawing
  - urban, raw, rebellious, edgy → graffiti marker
  - dark, anxious, heavy, dramatic → charcoal sketch
  - dreamy, fluid, soft, romantic → watercolor and ink
  - rural, narrative, folk, somber → cordel woodcut

  Output ONLY the chosen line.
  """

  @timeout_ms 5_000

  def palette, do: @palette

  @spec curate([String.t()], map()) :: {:ok, String.t()} | {:error, term()}
  def curate(lyrics, expressive) when is_list(lyrics) and lyrics != [] do
    cfg = Application.fetch_env!(:sinestesia, :config)
    url = Keyword.fetch!(cfg, :ollama_url) <> "/api/chat"

    body = %{
      model: Keyword.fetch!(cfg, :ollama_model),
      stream: false,
      think: false,
      options: %{temperature: 0.3, num_predict: 60},
      messages: [
        %{role: "system", content: @system},
        %{role: "user", content: render_user(lyrics, expressive)}
      ]
    }

    case Req.post(url, json: body, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}}}}
      when is_binary(content) and content != "" ->
        {:ok, snap_to_palette(content)}

      {:ok, resp} ->
        {:error, {:bad_response, resp.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def curate(_, _), do: {:error, :no_lyrics}

  defp render_user(lyrics, expressive) do
    joined = lyrics |> Enum.take(-8) |> Enum.join(" / ")
    voc = Map.get(expressive, "vocal_quality", "neutral")
    arousal = Map.get(expressive, "arousal", 0.5)
    valence = Map.get(expressive, "valence", 0.0)

    """
    LYRICS so far: "#{joined}"
    VOCAL: #{voc}, arousal #{Float.round(arousal * 1.0, 2)}, valence #{Float.round(valence * 1.0, 2)}

    Which style from the list fits this song best?
    """
  end

  # The model often returns extra commentary or quotes. Snap to the closest
  # palette item by simple substring match on distinctive keywords.
  defp snap_to_palette(raw) do
    text = raw |> String.trim() |> String.replace(~r/[\"\n\r]/, "") |> String.downcase()

    matches =
      @palette
      |> Enum.map(fn style ->
        key = keyword_for(style)
        score = if String.contains?(text, key), do: String.length(key), else: 0
        {style, score}
      end)
      |> Enum.filter(fn {_, score} -> score > 0 end)

    case matches do
      [] ->
        Logger.warning("[curator] no palette match for #{inspect(raw)}; using default")
        List.first(@palette)

      hits ->
        {style, _} = Enum.max_by(hits, fn {_, score} -> score end)
        style
    end
  end

  # Pick a distinctive keyword from each palette entry — the part that
  # uniquely identifies it (avoiding common words like "and", "with").
  defp keyword_for("loose ink sketch" <> _), do: "ink sketch"
  defp keyword_for("crayon" <> _), do: "crayon"
  defp keyword_for("graffiti" <> _), do: "graffiti"
  defp keyword_for("charcoal" <> _), do: "charcoal"
  defp keyword_for("watercolor" <> _), do: "watercolor"
  defp keyword_for("Brazilian cordel" <> _), do: "cordel"
  defp keyword_for(_), do: ""
end
