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

  describe "furthest_match/4 — bulk catch-up after an eager bootstrap" do
    test "with several lines' worth of accumulated text, returns the FURTHEST covered line" do
      accumulated =
        "Numa folha qualquer eu desenho um sol amarelo. " <>
          "E com cinco ou seis retas é fácil fazer um castelo. " <>
          "Corro o lápis em torno da mão e me dou uma luva."

      assert {:match, 2} = Follower.furthest_match(accumulated, @script, -1)
    end

    test "differs from match/4, which would prefer the NEAREST line instead" do
      accumulated =
        "Numa folha qualquer eu desenho um sol amarelo. " <>
          "E com cinco ou seis retas é fácil fazer um castelo."

      assert {:match, 1} = Follower.furthest_match(accumulated, @script, -1)
      # match/4 on the same blob would anchor on whichever nearby line scores
      # highest overlap, not necessarily the furthest one — the two functions
      # answer different questions on purpose.
      assert {:match, idx} = Follower.match(accumulated, @script, -1)
      assert idx <= 1
    end

    test "only the first line covered: catches up to exactly that line" do
      accumulated = "Numa folha qualquer eu desenho um sol amarelo."
      assert {:match, 0} = Follower.furthest_match(accumulated, @script, -1)
    end

    test "nothing recognizable yet: no match" do
      assert :no_match = Follower.furthest_match("", @script, -1)
      assert :no_match = Follower.furthest_match("completely unrelated words", @script, -1)
    end

    test "respects the window — a line beyond it is not considered even if covered" do
      long_script = @script ++ Enum.map(1..10, &"filler line number #{&1}")
      accumulated = Enum.join(long_script, ". ")
      # default window is 3, starting at cursor+1 = 0, so index 9 is out of reach
      assert {:match, idx} = Follower.furthest_match(accumulated, long_script, -1)
      assert idx <= 2
    end

    test "a covered line with an UNCOVERED gap before it is a later repeat, not real progress" do
      # Modeled on the live Fly Me To The Moon failure (HANDOFF gotcha #42).
      # Short lines of common words make coverage/2 — whose denominator is the
      # candidate line alone — cheap to clear by coincidence: line 9 shares
      # "and"/"let"/"me" with the opening and scores 3/4 = 0.75, well over the
      # threshold, despite not having been sung at all.
      script = [
        "Fly me to the Moon",
        "Let me play among the stars",
        "Let me see what spring is like",
        "On Jupiter and Mars",
        "In other words",
        "Hold my hand",
        "In other words",
        "Baby kiss me",
        "Fill my heart with song",
        "And let me sing"
      ]

      sung = "Fly me to the moon and let me play among the stars"

      # Only lines 0 and 1 were actually sung, and line 2 breaks the run, so
      # that's where the cursor belongs — NOT line 9, which the pre-fix
      # "furthest covered anywhere in the window" rule would have picked,
      # dragging the look-ahead eight lines past the performance.
      assert {:match, 1} = Follower.furthest_match(sung, script, -1, window: 12)
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
