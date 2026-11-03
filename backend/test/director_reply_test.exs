defmodule Sinestesia.DirectorReplyTest do
  @moduledoc """
  What the Director's reply becomes before it is a prompt.

  Every mode asks for ONE line; the model does not always comply. Seen live
  2026-11-03 (gemini-3.1-flash-lite, whole-scene mode): the reply carried
  the model's previous answers echoed back, four paragraphs each a superset
  of the last, and all of it reached the image provider and the debug strip.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sinestesia.Director

  test "a one-line reply passes through, quotes stripped" do
    assert Director.clean(~s|  "a person floating in space"  |) == "a person floating in space"
  end

  test "an echoed conversation keeps only the newest scene, and says so" do
    reply = """
    a person floating in space

    a person floating in space, glowing moon on the left

    a person floating in space, glowing moon on the left, silver stars scattered around.
    Tarsila do Amaral style, Brazilian modernism, bold colors and geometric shapes
    """

    log =
      capture_log(fn ->
        assert Director.clean(reply) ==
                 "Tarsila do Amaral style, Brazilian modernism, bold colors and geometric shapes"
      end)

    assert log =~ "replied with 4 lines where one was asked; keeping the last"
  end

  test "a preamble before the prompt is dropped, the prompt kept" do
    assert Director.clean("Here is the prompt:\n\"a red kite over the dunes\"") ==
             "a red kite over the dunes"
  end

  test "a compose-mode reply keeps its one NEW:/ATMOS: line intact" do
    assert Director.clean("NEW: a small castle | POS: right\n") ==
             "NEW: a small castle | POS: right"
  end

  test "an empty reply stays empty rather than crashing" do
    assert Director.clean("\n\n") == ""
  end
end
