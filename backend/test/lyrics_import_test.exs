defmodule Sinestesia.LyricsImportTest do
  use ExUnit.Case, async: true
  alias Sinestesia.LyricsImport

  describe "parser_for/1 — routing (no network)" do
    test "letras.mus.br and letras.com.br both route to the LetrasComBr parser" do
      assert {:ok, parser} =
               LyricsImport.parser_for("https://www.letras.mus.br/toquinho/aquarela/")

      assert parser == (&Sinestesia.LyricsImport.LetrasComBr.parse/1)

      assert {:ok, parser2} =
               LyricsImport.parser_for("https://www.letras.com.br/toquinho/aquarela/")

      assert parser2 == (&Sinestesia.LyricsImport.LetrasComBr.parse/1)
    end

    test "cifraclub.com.br routes to the CifraClub parser" do
      assert {:ok, parser} =
               LyricsImport.parser_for("https://www.cifraclub.com.br/toquinho/aquarela/")

      assert parser == (&Sinestesia.LyricsImport.CifraClub.parse/1)
    end

    test "an unrelated host is rejected clearly" do
      assert {:error, :unsupported_site} = LyricsImport.parser_for("https://example.com/song")
    end

    test "a garbage URL is rejected clearly" do
      assert {:error, :invalid_url} = LyricsImport.parser_for("not a url")
    end
  end

  describe "import/1 — end to end against the real fixtures, via the actual parser (no fetch)" do
    test "letras.mus.br parser reachable through the same code path import/1 would use" do
      {:ok, parser} = LyricsImport.parser_for("https://www.letras.mus.br/toquinho/aquarela/")
      html = Path.join(__DIR__, "fixtures/letras_aquarela.html") |> File.read!()
      assert {:ok, %{title: "Aquarela do Brasil"}} = parser.(html)
    end

    test "cifraclub parser reachable through the same code path import/1 would use" do
      {:ok, parser} = LyricsImport.parser_for("https://www.cifraclub.com.br/toquinho/aquarela/")
      html = Path.join(__DIR__, "fixtures/cifraclub_aquarela.html") |> File.read!()
      assert {:ok, %{title: "Aquarela"}} = parser.(html)
    end
  end

  test "import/1 rejects non-string input cleanly" do
    assert {:error, :invalid_url} = LyricsImport.import(nil)
  end
end
