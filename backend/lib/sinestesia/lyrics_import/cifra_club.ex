defmodule Sinestesia.LyricsImport.CifraClub do
  @moduledoc """
  Parses a cifraclub.com.br song page. Structure verified against a live fetch
  (2026-07-31), and genuinely messier than letras.mus.br — the chord chart and
  lyrics are interleaved in a single `<pre>` block:

      <div class="kvMV"><b data-chord-name="G" ...>G</b>   <b ...>G/B</b>
        Numa folha qualquer
      </div>

  Each sung line is one `<div class="kvMV">`: a line of chord names (as `<b>`
  tags) followed by the actual lyric text on its own line inside the SAME div.
  Fingerpicking/tab diagrams live in nested `<span class="tab">` blocks and
  carry no lyric text at all. Section labels (`[Primeira Parte]`, `[Refrão]`,
  ...) appear as their own `kvMV` div with no chord tags — used here as stanza
  boundaries, since Cifra Club doesn't otherwise mark blank lines between
  stanzas the way letras.mus.br does.

  This is inherently more fragile than the letras.mus.br parser (chord
  notation varies more page-to-page than plain lyric formatting does) — treat
  a parse failure here as more likely than there, and always let the operator
  fall back to pasting text directly.
  """
  alias Sinestesia.LyricsImport.Html

  @type result :: %{title: String.t() | nil, artist: String.t() | nil, lyrics_text: String.t()}

  @spec parse(String.t()) :: {:ok, result()} | {:error, term()}
  def parse(html) when is_binary(html) do
    with {:ok, pre} <- extract_pre_block(html),
         stanzas when stanzas != [] <- extract_stanzas(pre) do
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

  defp extract_pre_block(html) do
    case Regex.run(~r/<pre[^>]*>(.*?)<\/pre>/s, html) do
      [_, block] -> {:ok, block}
      nil -> {:error, :pre_block_not_found}
    end
  end

  defp extract_stanzas(pre) do
    pre
    # Fingerpicking/tab diagrams carry no lyric text — drop them before
    # splitting into lines, or their ASCII tab notation would be mistaken for
    # lyrics.
    |> drop_tab_spans()
    |> extract_kvmv_lines()
    |> group_into_stanzas()
  end

  defp drop_tab_spans(pre) do
    Regex.replace(~r/<span class="tab">.*?<\/span>/s, pre, "")
  end

  # Usually one `kvMV` div per sung/labeled line — strip the chord `<b>` tags
  # and what's left is either blank (a pure chord/instrumental line) or the
  # lyric text. BUT a section marker (`[Refrão 1]`, ...) is not always its own
  # div: it can sit on its OWN physical line INSIDE the same div as the last
  # lyric line of the section before it, joined by a literal newline in the
  # markup (observed: "Tenho um guarda-chuva\n\n[Pré-Refrão 1]"). So each div
  # is split into its own physical lines here, BEFORE grouping into stanzas —
  # one div can yield more than one entry.
  defp extract_kvmv_lines(pre) do
    ~r/<div class="kvMV">(.*?)<\/div>/s
    |> Regex.scan(pre)
    |> Enum.flat_map(fn [_, div_content] ->
      cleaned =
        ~r/<b[^>]*>.*?<\/b>/s
        |> Regex.replace(div_content, "")
        |> Html.strip_tags()
        |> Html.unescape()

      cleaned
      |> String.split(~r/\r?\n/)
      # Collapse the gaps left behind where an inline chord `<b>` tag used to
      # sit mid-line (e.g. "Vai voando,      contornando").
      |> Enum.map(&(&1 |> String.trim() |> String.replace(~r/\s{2,}/, " ")))
      |> Enum.reject(&(&1 == "" or not (&1 =~ ~r/\p{L}/u)))
    end)
  end

  # `[Section Name]` markers become stanza breaks; consecutive plain lyric
  # lines stay in the same stanza.
  defp group_into_stanzas(lines) do
    lines
    |> Enum.reduce([[]], fn line, [current | rest] = acc ->
      if section_marker?(line) do
        if current == [], do: acc, else: [[], current | rest]
      else
        [[line | current] | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reject(&(&1 == []))
    |> Enum.map(&Enum.join(&1, "\n"))
  end

  defp section_marker?(line), do: Regex.match?(~r/^\[.+\]$/, line)

  defp extract_title(html) do
    case Regex.run(~r/<title>([^<]+)<\/title>/, html) do
      [_, t] ->
        t |> String.split(" - ") |> List.first() |> Html.clean()

      nil ->
        nil
    end
  end

  defp extract_artist(html) do
    with [_, content] <- Regex.run(~r/<title>([^<]+)<\/title>/, html),
         parts <- String.split(content, " - "),
         true <- length(parts) >= 2 do
      parts |> Enum.at(1) |> Html.clean()
    else
      _ -> nil
    end
  end
end
