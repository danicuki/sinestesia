defmodule Sinestesia.MotionDirectorTest do
  use ExUnit.Case, async: true

  alias Sinestesia.MotionDirector

  describe "parse/2" do
    test "accepts exact 0-indexed coverage, tolerating fences and blanks" do
      raw = """
      ```
      0: the camera drifts toward the window
      1: leaves sway, light warms into the sun

      2: the scene settles into stillness
      ```
      """

      assert {:ok, directions} = MotionDirector.parse(raw, 3)
      assert length(directions) == 3
      assert hd(directions) =~ "drifts"
    end

    test "rejects the off-by-one overrun the lyrics chunker taught us about" do
      raw = "0: a\n1: b\n2: c\n3: d"
      assert {:error, {:bad_coverage, [0, 1, 2, 3]}} = MotionDirector.parse(raw, 3)
    end

    test "rejects gaps and unparseable lines" do
      assert {:error, {:bad_coverage, _}} = MotionDirector.parse("0: a\n2: c", 3)
      assert {:error, :unparseable} = MotionDirector.parse("sure! here are the shots", 2)
    end
  end

  describe "direct/3" do
    test "with no key, labels the result a FALLBACK so paid runs can warn" do
      # Test env has no google_api_key: direct must degrade — but never
      # silently. The {:fallback, _} tag is what lets the cost gate say
      # "GENERIC directions" before money is spent.
      assert {:fallback, directions} =
               Sinestesia.MotionDirector.direct("style", ["scene a", "scene b"], "la la")

      assert length(directions) == 2
    end
  end

  describe "fallback/1" do
    test "each direction travels toward the NEXT scene; the last settles" do
      [d0, d1] = MotionDirector.fallback(["a blue window", "a paper sun"])
      assert d0 =~ "a paper sun"
      refute d1 =~ "transforming"
      assert d1 =~ "settling"
    end
  end
end
