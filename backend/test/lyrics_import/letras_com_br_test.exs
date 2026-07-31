defmodule Sinestesia.LyricsImport.LetrasComBrTest do
  use ExUnit.Case, async: true
  alias Sinestesia.LyricsImport.LetrasComBr

  @fixture Path.join(__DIR__, "../fixtures/letras_aquarela.html") |> File.read!()

  test "parses title, artist, and stanza-separated lyrics from a real fetched page" do
    assert {:ok, %{title: title, artist: artist, lyrics_text: text}} = LetrasComBr.parse(@fixture)

    assert title == "Aquarela do Brasil"
    assert artist == "Toquinho"
    assert text =~ "Brasil meu Brasil brasileiro"
    assert text =~ "Meu mulato inzoneiro"

    # Stanzas are blank-line separated — MusicalStructure.analyze/1 relies on
    # exactly this to detect verse/chorus. This song has 5 distinct stanzas
    # (each opens with the same "Brasil, Brasil / Pra mim, pra mim" callback,
    # but the rest of each stanza differs — a hook within each verse, not a
    # standalone repeated chorus stanza under our strict whole-stanza definition).
    stanzas = String.split(text, "\n\n")
    assert length(stanzas) == 5
  end

  test "the parsed lyrics feed MusicalStructure without error" do
    {:ok, %{lyrics_text: text}} = LetrasComBr.parse(@fixture)
    structure = Sinestesia.MusicalStructure.analyze(text)

    # 5 distinct stanzas, no full-stanza repeat in THIS song, so no chorus is
    # detected under the strict "whole stanza repeats" definition — correct,
    # not a bug: verifies real-world scraped text round-trips cleanly through
    # structure analysis, not that this particular song has a chorus.
    assert length(structure.sections) == 5
    assert Enum.all?(structure.sections, &(&1.label == :verse))
  end

  test "no lyric-original block: a clear error, not a crash" do
    assert {:error, :lyric_block_not_found} = LetrasComBr.parse("<html><body>nope</body></html>")
  end

  test "invalid input is rejected cleanly" do
    assert {:error, :invalid_html} = LetrasComBr.parse(nil)
  end
end
