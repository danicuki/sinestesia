defmodule Sinestesia.LyricsImport do
  @moduledoc """
  Turns a lyrics-site URL into `{title, artist, lyrics_text}` — the raw text
  format `Sinestesia.MusicalStructure.analyze/1` expects (blank lines between
  stanzas) — so a song can be added to `Sinestesia.SongLibrary` by pasting a
  link instead of copying lyrics by hand.

  Dispatches to a per-site parser based on the URL's host. Each parser is
  pure (HTML in, `{:ok, result} | {:error, reason}` out — see
  `Sinestesia.LyricsImport.LetrasComBr` and `.CifraClub`) and independently
  tested against real fetched fixtures; this module owns only the fetch +
  routing.

  Cifra Club's markup (chords interleaved with lyrics) is inherently more
  fragile than letras.mus.br's (plain `<p>`/`<br>` stanzas) — a parse failure
  there is more likely than here. Either way, a failure is always a clear
  `{:error, reason}`, never a silent bad result: this is meant to save typing,
  not to be trusted blindly — the operator still sees what was imported
  before it's used live.
  """
  require Logger

  @type result :: %{title: String.t() | nil, artist: String.t() | nil, lyrics_text: String.t()}

  @user_agent "Mozilla/5.0 (compatible; Sinestesia/1.0; +https://github.com/danicuki/sinestesia)"

  @doc "Fetch and parse a lyrics-site URL. `{:error, :unsupported_site}` for anything else."
  @spec import(String.t()) :: {:ok, result()} | {:error, term()}
  def import(url) when is_binary(url) do
    case parser_for(url) do
      {:ok, parser} -> fetch_and_parse(url, parser)
      {:error, reason} -> {:error, reason}
    end
  end

  def import(_), do: {:error, :invalid_url}

  @doc false
  # Exposed for testing the routing decision without a real network call.
  @spec parser_for(String.t()) ::
          {:ok, (String.t() -> {:ok, result()} | {:error, term()})} | {:error, term()}
  def parser_for(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        cond do
          host =~ ~r/(^|\.)letras\.(mus|com)\.br$/ ->
            {:ok, &Sinestesia.LyricsImport.LetrasComBr.parse/1}

          host =~ ~r/(^|\.)cifraclub\.com\.br$/ ->
            {:ok, &Sinestesia.LyricsImport.CifraClub.parse/1}

          true ->
            {:error, :unsupported_site}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  defp fetch_and_parse(url, parser) do
    case Req.get(url,
           headers: [{"user-agent", @user_agent}],
           receive_timeout: 15_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        parser.(html)

      {:ok, %{status: status}} ->
        Logger.warning("[lyrics_import] #{url} returned HTTP #{status}")
        {:error, {:bad_status, status}}

      {:error, reason} ->
        Logger.warning("[lyrics_import] fetch failed for #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
