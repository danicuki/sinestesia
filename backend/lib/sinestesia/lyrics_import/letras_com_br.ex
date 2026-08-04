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

  # The site's own search backend (observed in the page's autocomplete,
  # verified live 2026-08-04). Guessing URL slugs from a title/artist is a
  # trap — letras localizes them ("Simon & Garfunkel" lives at
  # /simon-e-garfunkel/) — so asking the search index for the real `dns`
  # (artist slug) and song id is the only reliable route.
  @search_url "https://solr.sscdn.co/letras/m1/"

  @doc """
  Search letras.mus.br for a song; returns candidate song-page URLs, best
  match first. Network errors return `[]` — the caller has slug-guess
  fallbacks and a transcript verification behind this.
  """
  @spec search(String.t(), keyword()) :: [String.t()]
  def search(query, opts \\ []) when is_binary(query) do
    # Solr chokes on query operators — "Simon & Garfunkel" finds NOTHING
    # with the ampersand and 182 hits without it. Letters, digits and
    # spaces only.
    query = query |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ") |> String.trim()

    case Req.get(Keyword.get(opts, :search_url, @search_url),
           params: [q: query, wt: "json"],
           headers: [{"user-agent", "Mozilla/5.0"}],
           receive_timeout: 10_000,
           retry: false,
           # The body is JSONP (LetrasSug({...})) served as json — Req's
           # auto-decode chokes on the callback wrapper and turns the whole
           # response into {:error, %Jason.DecodeError{}}.
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # JSONP: LetrasSug({...}) — strip the callback wrapper.
        with %{"response" => %{"docs" => docs}} <-
               body
               |> String.replace(~r/^[A-Za-z]+\(/, "")
               |> String.trim() |> String.trim_trailing(")")
               |> Jason.decode!()  do
          docs
          |> Enum.filter(&(is_binary(&1["dns"]) and is_binary(&1["url"])))
          |> Enum.map(&"https://www.letras.mus.br/#{&1["dns"]}/#{&1["url"]}/")
          |> Enum.uniq()
          |> Enum.take(3)
        else
          _ -> []
        end

      _ ->
        []
    end
  rescue
    # A malformed search response must degrade to "no candidates", never
    # take down song resolution — the slug guesses still run after us.
    _ -> []
  end

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
