defmodule Sinestesia.MusicalStructureTest do
  use ExUnit.Case, async: true
  alias Sinestesia.MusicalStructure, as: MS

  @song """
  Numa folha qualquer eu desenho um sol amarelo
  E com cinco ou seis retas é fácil fazer um castelo

  Águas de março fechando o verão
  É a promessa de vida no teu coração

  Vai vai vai, aquarela do Brasil
  Vai vai vai, pinta o campo e o gentil

  Corro o lápis em torno da mão
  E me dou uma luva, e se faço chover

  Vai vai vai, aquarela do Brasil
  Vai vai vai, pinta o campo e o gentil

  Ele vai pousar
  """

  describe "analyze/1 — sectioning" do
    test "splits stanzas on blank lines" do
      s = MS.analyze(@song)
      assert length(s.sections) == 6
      assert length(s.lines) == 11
    end

    test "the repeated stanza is labeled chorus, with occurrence counting" do
      s = MS.analyze(@song)
      choruses = Enum.filter(s.sections, &(&1.label == :chorus))
      assert length(choruses) == 2
      assert Enum.map(choruses, & &1.occurrence) == [1, 2]
    end

    test "the first stanza and other unrepeated stanzas before the chorus are verses" do
      s = MS.analyze(@song)
      assert Enum.at(s.sections, 0).label == :verse
      assert Enum.at(s.sections, 1).label == :verse
    end

    test "a unique stanza after the chorus has established is a bridge" do
      s = MS.analyze(@song)
      # section 3: "Corro o lápis..." — unique, appears after the chorus already seen
      assert Enum.at(s.sections, 3).label == :bridge
    end

    test "a short unique final stanza is an outro" do
      s = MS.analyze(@song)
      last = List.last(s.sections)
      assert last.label == :outro
      assert last.lines == ["Ele vai pousar"]
    end

    test "line_section maps every flat line index to its section id" do
      s = MS.analyze(@song)
      assert map_size(s.line_section) == length(s.lines)
      # line 0 is in section 0, the last line is in the last section
      assert s.line_section[0] == 0
      assert s.line_section[length(s.lines) - 1] == List.last(s.sections).id
    end
  end

  describe "analyze/1 — no repetition" do
    test "a song with no repeated stanza has no chorus" do
      text = "verse one line a\nverse one line b\n\nverse two line a\nverse two line b"
      s = MS.analyze(text)
      refute Enum.any?(s.sections, &(&1.label == :chorus))
      assert Enum.all?(s.sections, &(&1.label == :verse))
    end
  end

  describe "analyze/1 — flat list input (no stanza info)" do
    test "a flat list of lines becomes a single section" do
      s = MS.analyze(["a", "b", "c"])
      assert length(s.sections) == 1
      assert hd(s.sections).label == :verse
      assert s.lines == ["a", "b", "c"]
    end
  end

  describe "analyze/1 — empty / nil" do
    test "nil input yields an empty structure" do
      assert %{lines: [], sections: [], line_section: %{}} = MS.analyze(nil)
    end

    test "blank text yields an empty structure" do
      assert %{lines: [], sections: []} = MS.analyze("\n\n  \n")
    end
  end

  describe "label_at/2 and section_at/2" do
    test "returns the right label for a mid-song line" do
      s = MS.analyze(@song)
      # First chorus occurrence starts right after the two verses (lines 0-3), at line 4
      assert MS.label_at(s, 4) == :chorus
    end

    test "returns nil out of range" do
      s = MS.analyze(@song)
      assert MS.label_at(s, 999) == nil
      assert MS.section_at(s, 999) == nil
    end
  end

  describe "hint/1" do
    test "nil section yields no hint" do
      assert MS.hint(nil) == ""
    end

    test "first chorus occurrence" do
      assert MS.hint(%{label: :chorus, occurrence: 1}) == " [chorus begins]"
    end

    test "a returning chorus names its occurrence and asks for the echo" do
      assert MS.hint(%{label: :chorus, occurrence: 2}) ==
               " [chorus returns (#2) — echo its established imagery]"

      assert MS.hint(%{label: :chorus, occurrence: 5}) =~ "#5"
    end

    test "bridge and outro get their own hints" do
      assert MS.hint(%{label: :bridge, occurrence: 1}) == " [bridge — a shift in the scene]"
      assert MS.hint(%{label: :outro, occurrence: 1}) == " [song's outro]"
    end

    test "a plain (first-occurrence, non-repeated) verse gets no hint" do
      assert MS.hint(%{label: :verse, occurrence: 1}) == ""
    end
  end

  describe "boundary?/3" do
    test "true crossing from one section into the next" do
      s = MS.analyze(@song)
      # line 1 -> line 2 crosses from section 0 into section 1
      assert MS.boundary?(s, 1, 2)
    end

    test "false moving within the same section" do
      s = MS.analyze(@song)
      refute MS.boundary?(s, 0, 1)
    end

    test "true entering the first section from before the song (-1)" do
      s = MS.analyze(@song)
      assert MS.boundary?(s, -1, 0)
    end

    test "false when curr is out of range" do
      s = MS.analyze(@song)
      refute MS.boundary?(s, 0, 999)
    end
  end
end
