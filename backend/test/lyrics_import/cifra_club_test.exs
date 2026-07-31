defmodule Sinestesia.LyricsImport.CifraClubTest do
  use ExUnit.Case, async: true
  alias Sinestesia.LyricsImport.CifraClub

  @fixture Path.join(__DIR__, "../fixtures/cifraclub_aquarela.html") |> File.read!()

  test "parses title, artist, and lyrics (chords/tabs stripped) from a real fetched page" do
    assert {:ok, %{title: title, artist: artist, lyrics_text: text}} = CifraClub.parse(@fixture)

    assert title == "Aquarela"
    assert artist == "Toquinho"
    assert text =~ "Numa folha qualquer"
    assert text =~ "Eu desenho um sol amarelo"
    assert text =~ "E com cinco ou seis retas"

    # No chord names or tab notation should leak into the lyric text.
    refute text =~ "data-chord-name"
    refute text =~ "|---"
    refute text =~ ~r/^\s*[GCDAEF](\/[A-G])?\s*$/m
  end

  test "section markers ([Refrão], [Segunda Parte], ...) are consumed as stanza breaks, not left as text" do
    {:ok, %{lyrics_text: text}} = CifraClub.parse(@fixture)

    refute text =~ "Refrão"
    refute text =~ "Parte"
    refute text =~ "Final"
    refute text =~ ~r/\[.+\]/

    # A section marker can share its raw HTML div with the LAST lyric line of
    # the section before it (observed: "...guarda-chuva\n\n[Pré-Refrão 1]") —
    # that line must still end up in the PRECEDING stanza, not get dropped.
    assert text =~ "Tenho um guarda-chuva"

    # Real stanza boundaries exist (the marker splits sung sections apart).
    assert length(String.split(text, "\n\n")) > 1
  end

  test "collapses the whitespace gaps left where inline chords used to sit" do
    {:ok, %{lyrics_text: text}} = CifraClub.parse(@fixture)

    refute text =~ ~r/[^\S\n]{2,}/
    assert text =~ "Vai voando, contornando"
  end

  test "the parsed lyrics feed MusicalStructure without error" do
    {:ok, %{lyrics_text: text}} = CifraClub.parse(@fixture)
    structure = Sinestesia.MusicalStructure.analyze(text)

    assert length(structure.sections) >= 1
    assert structure.lines != []
  end

  test "no <pre> block: a clear error, not a crash" do
    assert {:error, :pre_block_not_found} = CifraClub.parse("<html><body>nope</body></html>")
  end

  test "invalid input is rejected cleanly" do
    assert {:error, :invalid_html} = CifraClub.parse(nil)
  end
end
