defmodule Sinestesia.TempoTest do
  use ExUnit.Case, async: true
  alias Sinestesia.Tempo

  @unknown %{bpm: nil, at: 0}

  describe "smooth/3 — first reading" do
    test "a plausible first reading is adopted outright" do
      r = Tempo.smooth(@unknown, 100, 1_000)
      assert_in_delta r.bpm, 100.0, 0.001
      assert r.at == 1_000
    end

    test "an implausible first reading stays unknown" do
      assert %{bpm: nil} = Tempo.smooth(@unknown, 20, 1_000)
      assert %{bpm: nil} = Tempo.smooth(@unknown, 400, 1_000)
      assert %{bpm: nil} = Tempo.smooth(@unknown, nil, 1_000)
      assert %{bpm: nil} = Tempo.smooth(@unknown, :not_a_number, 1_000)
    end
  end

  describe "smooth/3 — steady state" do
    test "repeated consistent readings converge toward the true value" do
      r =
        Enum.reduce(1..20, @unknown, fn i, acc ->
          Tempo.smooth(acc, 100, i * 500)
        end)

      assert_in_delta r.bpm, 100.0, 0.5
    end

    test "a single noisy reading moves the estimate only a little (smoothed, not snapped)" do
      steady = Tempo.smooth(@unknown, 100, 1_000)
      noisy = Tempo.smooth(steady, 180, 1_500)
      # With alpha 0.25, a jump from 100 to 180 should land around 120, not 180.
      assert noisy.bpm > 100.0
      assert noisy.bpm < 140.0
    end

    test "an implausible reading mid-stream is ignored, keeping the live prior" do
      steady = Tempo.smooth(@unknown, 100, 1_000)
      still = Tempo.smooth(steady, 9999, 1_500)
      assert_in_delta still.bpm, 100.0, 0.001
      # `at` is untouched too — an ignored reading isn't "fresh".
      assert still.at == 1_000
    end
  end

  describe "smooth/3 — staleness" do
    test "a live estimate survives a short gap of missing readings" do
      steady = Tempo.smooth(@unknown, 100, 1_000)
      still = Tempo.smooth(steady, nil, 1_000 + 3_000)
      assert_in_delta still.bpm, 100.0, 0.001
    end

    test "a stale estimate ages out to unknown" do
      steady = Tempo.smooth(@unknown, 100, 1_000)
      aged = Tempo.smooth(steady, nil, 1_000 + 9_000)
      assert aged.bpm == nil
    end

    test "an already-unknown reading with a missing follow-up stays unknown" do
      aged = Tempo.smooth(@unknown, nil, 50_000)
      assert aged.bpm == nil
    end
  end

  describe "plausible?/1" do
    test "accepts the singing-tempo band" do
      assert Tempo.plausible?(50)
      assert Tempo.plausible?(120)
      assert Tempo.plausible?(200)
    end

    test "rejects outside the band and non-numbers" do
      refute Tempo.plausible?(49)
      refute Tempo.plausible?(201)
      refute Tempo.plausible?(nil)
      refute Tempo.plausible?("120")
    end
  end

  describe "display/1" do
    test "rounds a known bpm" do
      assert Tempo.display(%{bpm: 95.6, at: 0}) == 96
    end

    test "nil for unknown" do
      assert Tempo.display(%{bpm: nil, at: 0}) == nil
      assert Tempo.display(%{}) == nil
    end
  end
end
