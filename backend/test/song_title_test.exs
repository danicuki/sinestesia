defmodule Sinestesia.SongTitleTest do
  @moduledoc """
  What an unidentified performance gets called.

  Identification fails often enough to matter — a provider times out, no key is
  configured, or the model honestly declines to guess at a garbled transcript —
  and the name it falls back to is minted on-chain permanently.
  """
  use ExUnit.Case, async: true

  alias Sinestesia.Pipeline

  test "names the performance after its opening words" do
    assert Pipeline.opening_line(
             "Numa folha qualquer eu desenho um sol amarelo e com cinco ou seis retas"
           ) == "Numa folha qualquer eu desenho…"
  end

  test "the ellipsis marks it as an excerpt, not a claimed title" do
    # Five words or fewer is the whole transcript, so nothing was cut and there
    # is nothing to signal.
    assert Pipeline.opening_line("Hold my hand") == "Hold my hand"
    assert Pipeline.opening_line("um dois tres quatro cinco") == "um dois tres quatro cinco"
    assert Pipeline.opening_line("um dois tres quatro cinco seis") =~ "…"
  end

  test "tidies whitespace and a comma left dangling by the cut" do
    assert Pipeline.opening_line("  Vai   voando  ") == "Vai voando"

    # The fifth word ends the excerpt mid-clause; its comma would otherwise be
    # stranded in front of the ellipsis.
    assert Pipeline.opening_line("Num instante imagino uma gaivota, voando alto") ==
             "Num instante imagino uma gaivota…"

    # Commas inside the excerpt are part of the lyric and stay.
    assert Pipeline.opening_line("Baby, kiss me now") == "Baby, kiss me now"
  end

  test "falls back to Untitled only when there is no transcript at all" do
    # An instrumental, or a mint fired before anyone sang.
    assert Pipeline.opening_line("") == "Untitled"
    assert Pipeline.opening_line("   ") == "Untitled"
    assert Pipeline.opening_line(nil) == "Untitled"
  end

  test "a single word is a title, not a failure" do
    assert Pipeline.opening_line("Isso") == "Isso"
  end
end
