defmodule Sinestesia.SttBenchTest do
  use ExUnit.Case, async: true

  alias Sinestesia.SttBench

  describe "tokens/1" do
    test "folds case, accents, punctuation and held notes like the follower" do
      assert SttBench.tokens("É fácil fazer um casteloooo, né?") ==
               ~w(e facil fazer um castelo ne)
    end

    test "keeps real double letters" do
      assert SttBench.tokens("Corro o carro") == ~w(corro o carro)
    end
  end

  describe "wer/2" do
    test "counts substitutions, deletions and insertions over the reference length" do
      ref = ~w(numa folha qualquer eu desenho)
      assert %{errors: 0, n: 5, wer: +0.0} = SttBench.wer(ref, ref)
      # one deletion ("eu") + one substitution ("desenha")
      assert %{errors: 2, wer: 0.4} = SttBench.wer(ref, ~w(numa folha qualquer desenha))
      assert %{errors: 5, wer: 1.0} = SttBench.wer(ref, [])
    end

    test "an empty reference has no rate" do
      assert %{wer: nil, n: 0} = SttBench.wer([], ~w(anything))
    end
  end

  describe "local_align/3" do
    test "pairs the shared stretch and tolerates a one-letter slip" do
      a = ~w(e com cinco ou seis retas)
      b = ~w(um sol amarelo e com cinco ou seis retaz e facil)
      assert SttBench.local_align(a, b) == [{0, 3}, {1, 4}, {2, 5}, {3, 6}, {4, 7}, {5, 8}]
    end

    test "on a repeated phrase, prefers the later occurrence by default and the earlier on request" do
      b = ~w(azzurro il pomeriggio x y z azzurro il pomeriggio)
      a = ~w(azzurro il pomeriggio)
      assert [{0, 6} | _] = SttBench.local_align(a, b)
      assert [{0, 0} | _] = SttBench.local_align(a, b, prefer: :first)
    end

    test "nothing in common aligns to nothing" do
      assert SttBench.local_align(~w(hast du etwas zeit), ~w(numa folha qualquer)) == []
    end
  end

  test "locate/2 finds the clip's span inside the lyrics" do
    lyrics = ~w(intro words here numa folha qualquer eu desenho um sol amarelo e com cinco)
    anchor = ~w(numa folha qualquer eu desenho um sol)
    assert SttBench.locate(anchor, lyrics) == {3, 9}
  end

  describe "lags/2" do
    @anchor [
      %{token: "numa", end: 1.0},
      %{token: "folha", end: 1.5},
      %{token: "qualquer", end: 2.0},
      %{token: "eu", end: 3.0},
      %{token: "desenho", end: 3.5}
    ]

    test "measures from the last sung word an event contains" do
      events = [%{t: 2_600, text: "Numa folha qualquer"}, %{t: 4_400, text: "eu desenho"}]
      assert SttBench.lags(events, @anchor) == [600.0, 900.0]
    end

    test "never credits an event with words not yet sung when it arrived" do
      # "eu desenho" ends at 3.5s; an event at 1.2s can only be placed on
      # what was sung by then (+0.5s slack) — here nothing it contains.
      assert SttBench.lags([%{t: 1_200, text: "eu desenho"}], @anchor) == []
    end
  end

  test "follow/3 confirms lines in order, including two sung in one breath" do
    lines = ["Numa folha qualquer", "Eu desenho um sol amarelo", "E com cinco ou seis retas"]
    finals = [
      %{t: 3_000, text: "numa folha qualquer"},
      %{t: 9_000, text: "eu desenho um sol amarelo e com cinco ou seis retas"}
    ]

    assert %{confirmed: 3, lines: 3, delays: delays} = SttBench.follow(finals, lines, [2.0, 5.0, 8.0])
    assert delays == [1_000.0, 1_000.0, 4_000.0]
  end

  test "pct/2 interpolates" do
    assert SttBench.pct([1, 2, 3, 4], 50) == 2.5
    assert SttBench.pct([], 50) == nil
  end
end
