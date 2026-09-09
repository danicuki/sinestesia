defmodule Mix.Tasks.Sinestesia.VideoLimitTest do
  use ExUnit.Case, async: true

  # --limit exists so motion-mode tests don't bill a whole song: events past
  # the mark must never reach the replay (nothing beyond gets directed,
  # rendered, or paid for).

  @events [
    %{"at_ms" => 2_000, "final" => true, "text" => "primeira"},
    %{"at_ms" => 19_500, "final" => false, "text" => "segu-"},
    %{"at_ms" => 21_000, "final" => true, "text" => "segunda"},
    %{"at_ms" => 34_000, "final" => true, "text" => "terceira"}
  ]

  test "events past the mark are cut, on the performance clock" do
    kept = Mix.Tasks.Sinestesia.Video.limit_events(@events, 20_000)
    assert Enum.map(kept, & &1["text"]) == ["primeira", "segu-"]
  end

  test "no limit means no cut" do
    assert Mix.Tasks.Sinestesia.Video.limit_events(@events, nil) == @events
  end
end
