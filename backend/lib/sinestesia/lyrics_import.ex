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

  Since 2026-10 letras.mus.br sits behind Akamai bot protection that rejects
  every non-browser HTTP client by TLS fingerprint — no User-Agent or header
  combination gets past it (verified: plain curl, full Chrome header sets and
  Googlebot all return the same edgesuite 403). When the direct fetch fails,
  we fetch the same URL's latest Internet Archive snapshot (`web.archive.org`,
  `id_` raw mode so the original bytes arrive unmodified) and feed it to the
  same parser. Lyrics don't change, so a years-old snapshot is as good as
  today's page; the real limitation is coverage — a page the Archive never
  crawled has no fallback, and the operator should paste the lyrics text
  instead.
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
    case fetch(url, 15_000) do
      {:ok, html} ->
        parser.(html)

      {:error, reason} ->
        Logger.warning(
          "[lyrics_import] #{url} failed (#{inspect(reason)}) — the site blocks non-browser clients; trying the Internet Archive copy"
        )

        fetch_snapshot_and_parse(url, parser, reason)
    end
  end

  defp fetch_snapshot_and_parse(url, parser, original_reason) do
    # The Archive redirects /web/2id_/<url> to the latest snapshot; it can be
    # slow, but this runs in the operator's import flow, never mid-song.
    case fetch(snapshot_url(url), 30_000) do
      {:ok, html} ->
        case parser.(html) do
          {:ok, result} ->
            Logger.info("[lyrics_import] imported from the Internet Archive copy of #{url}")
            {:ok, result}

          {:error, parse_reason} ->
            Logger.warning(
              "[lyrics_import] the Internet Archive copy of #{url} did not parse (#{inspect(parse_reason)}) — paste the lyrics text instead"
            )

            {:error, original_reason}
        end

      {:error, snapshot_reason} ->
        Logger.warning(
          "[lyrics_import] no usable Internet Archive copy of #{url} (#{inspect(snapshot_reason)}) — paste the lyrics text instead"
        )

        # The original failure names the actual site, which is the error that
        # explains what happened; the missing snapshot is only why the rescue
        # didn't work.
        {:error, original_reason}
    end
  end

  @doc false
  # `id_` asks the Archive for the original bytes, with none of the wayback
  # toolbar or URL rewriting injected — the parsers see the page as it was
  # served. The bare `2` timestamp prefix means "latest snapshot".
  @spec snapshot_url(String.t()) :: String.t()
  def snapshot_url(url), do: "https://web.archive.org/web/2id_/" <> url

  defp fetch(url, timeout) do
    case Req.get(url,
           headers: [{"user-agent", @user_agent}],
           receive_timeout: timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        {:ok, html}

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
