defmodule Sinestesia.PipelineTranscriptTest do
  use ExUnit.Case, async: true

  alias Sinestesia.Pipeline

  # Some STT models wrap what they heard in `<<...>>`; the markers reached the
  # stage's karaoke line (2026-11-02). Every provider's text is cleaned at the
  # pipeline's door, so the Director, the lyric record and the NFT never see
  # them — whatever model is on duty.
  describe "clean_transcript/1" do
    test "strips << >> wrapping a phrase" do
      assert Pipeline.clean_transcript("<<numa folha qualquer eu desenho um sol amarelo>>") ==
               "numa folha qualquer eu desenho um sol amarelo"
    end

    test "strips markers inside a phrase and trims what is left" do
      assert Pipeline.clean_transcript("  <<e com cinco>> ou seis <<retas>> ") ==
               "e com cinco ou seis retas"
    end

    test "leaves ordinary text alone, a lone angle bracket included" do
      assert Pipeline.clean_transcript("a > b, e <3 você") == "a > b, e <3 você"
    end

    test "anything but a string is an empty transcript" do
      assert Pipeline.clean_transcript(nil) == ""
    end
  end
end
