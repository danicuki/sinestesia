defmodule Sinestesia.PerformanceFollowerTest do
  use ExUnit.Case, async: true
  alias Sinestesia.PerformanceFollower, as: Follower

  @script [
    "Numa folha qualquer eu desenho um sol amarelo",
    "E com cinco ou seis retas é fácil fazer um castelo",
    "Corro o lápis em torno da mão e me dou uma luva",
    "E se faço chover com dois riscos tenho um guarda-chuva"
  ]

  describe "match/4 — sequential progress" do
    test "exact line advances to its index" do
      assert {:match, 0} =
               Follower.match("Numa folha qualquer eu desenho um sol amarelo", @script, -1)

      assert {:match, 1} =
               Follower.match("E com cinco ou seis retas é fácil fazer um castelo", @script, 0)
    end

    test "tolerates STT typos and dropped words" do
      # a couple of words off — still clearly line 1
      assert {:match, 1} =
               Follower.match("com cinco ou seis retas fazer um castelo", @script, 0)
    end

    test "folds accents (STT may drop diacritics)" do
      assert {:match, 0} =
               Follower.match("numa folha qualquer eu desenho um sol amarelo", @script, -1)
    end

    test "a sung fragment (subset of the line) still matches" do
      assert {:match, 2} = Follower.match("me dou uma luva", @script, 1)
    end
  end

  describe "match/4 — jumps and repeats" do
    test "a skipped line is found within the look-ahead window" do
      # from cursor 0, singer jumps to line 2
      assert {:match, 2} =
               Follower.match("Corro o lápis em torno da mão e me dou uma luva", @script, 0)
    end

    test "a repeated (already-sung) line matches its own index, not forward" do
      assert {:match, 0} =
               Follower.match("Numa folha qualquer eu desenho um sol amarelo", @script, 0)
    end
  end

  describe "match/4 — off script" do
    test "an improvised line does not match" do
      assert :no_match =
               Follower.match("oh yeah baby improvising something wild", @script, 0)
    end

    test "empty input never matches" do
      assert :no_match = Follower.match("", @script, -1)
      assert :no_match = Follower.match("   ", @script, -1)
    end

    test "a line far beyond the window is not matched" do
      # cursor 0, default window 3 → line 3 is reachable, but a far jump isn't
      short = @script ++ Enum.map(1..10, &"filler line number #{&1}")
      assert :no_match = Follower.match("filler line number 9", short, 0)
    end
  end

  describe "normalize/1" do
    test "splits a blob on newlines and drops blanks" do
      assert ["a", "b"] = Follower.normalize("a\n\n  b  \n")
    end

    test "trims a list and drops empties" do
      assert ["a", "b"] = Follower.normalize([" a ", "", "b", "   "])
    end
  end
end
