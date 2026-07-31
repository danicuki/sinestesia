defmodule Sinestesia.LyricsImport.LetrasComBr do
  @moduledoc """
  Parses a letras.mus.br song page (letras.com.br 301-redirects here — both
  names are accepted by `Sinestesia.LyricsImport`). Structure verified against
  a live fetch (2026-07-31):

      <div class="lyric-original"><p>line one<br/>line two</p><p>...</p></div>

  One `<p>` per STANZA, lines separated by `<br/>` — this maps directly onto
  `Sinestesia.MusicalStructure`'s blank-line-stanza format, so no translation
  is needed beyond joining stanzas with a blank line.
  """
  alias Sinestesia.LyricsImport.Html

  @type result :: %{title: String.t() | nil, artist: String.t() | nil, lyrics_text: String.t()}

  @spec parse(String.t()) :: {:ok, result()} | {:error, term()}
  def parse(html) when is_binary(html) do
    with {:ok, block} <- extract_lyric_block(html),
         stanzas when stanzas != [] <- extract_stanzas(block) do
      {:ok,
       %{
         title: extract_title(html),
         artist: extract_artist(html),
         lyrics_text: Enum.join(stanzas, "\n\n")
       }}
    else
      {:error, reason} -> {:error, reason}
      [] -> {:error, :no_lyrics_found}
    end
  end

  def parse(_), do: {:error, :invalid_html}

  defp extract_lyric_block(html) do
    case Regex.run(~r/<div class="lyric-original">(.*?)<\/div>/s, html) do
      [_, block] -> {:ok, block}
      nil -> {:error, :lyric_block_not_found}
    end
  end

  defp extract_stanzas(block) do
    ~r/<p>(.*?)<\/p>/s
    |> Regex.scan(block)
    |> Enum.map(fn [_, p] ->
      p
      |> String.split(~r/<br\s*\/?>/i)
      |> Enum.map(&Html.clean/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # <h1>Song</h1> ... <h2>Artist</h2> sit right next to each other in the page
  # header — more reliable than parsing "Song - Artist - LETRAS.MUS.BR" out of
  # <title>/og:title, which is used only as a fallback.
  defp extract_title(html) do
    case Regex.run(~r/<h1>([^<]+)<\/h1>/, html) do
      [_, t] -> Html.clean(t)
      nil -> title_from_meta(html)
    end
  end

  defp extract_artist(html) do
    case Regex.run(~r/<h1>[^<]+<\/h1>\s*<\/div><a[^>]*><h2>([^<]+)<\/h2>/, html) do
      [_, a] -> Html.clean(a)
      nil -> artist_from_meta(html)
    end
  end

  defp title_from_meta(html) do
    with [_, content] <- Regex.run(~r/<meta property="og:title" content="([^"]+)"/, html),
         [title | _] <- String.split(content, " - ") do
      Html.clean(title)
    else
      _ -> nil
    end
  end

  defp artist_from_meta(html) do
    with [_, content] <- Regex.run(~r/<meta property="og:title" content="([^"]+)"/, html),
         parts <- String.split(content, " - "),
         true <- length(parts) >= 2 do
      parts |> Enum.at(1) |> Html.clean()
    else
      _ -> nil
    end
  end
end
