defmodule Sinestesia.LyricsChunkerTest do
  @moduledoc """
  Only the pure, no-network parts of Sinestesia.LyricsChunker: the
  one-chunk-per-line fallback (the safety net every caller in pipeline.ex
  relies on being correct) and the trivial empty-script case. The real LLM
  call is exercised live (mix sinestesia.replay / the actual show), same as
  Sinestesia.SongId — there is no hermetic test for that half either.
  """
  use ExUnit.Case, async: true

  alias Sinestesia.LyricsChunker

  test "fallback/1 is one chunk per line, in order, covering the whole script" do
    lines = ["Numa folha qualquer", "Eu desenho um sol amarelo", "E com cinco ou seis retas"]

    assert LyricsChunker.fallback(lines) == [
             %{start_line: 0, end_line: 0, text: "Numa folha qualquer"},
             %{start_line: 1, end_line: 1, text: "Eu desenho um sol amarelo"},
             %{start_line: 2, end_line: 2, text: "E com cinco ou seis retas"}
           ]
  end

  test "fallback/1 on an empty script is an empty list" do
    assert LyricsChunker.fallback([]) == []
  end

  test "chunk/1 on an empty script short-circuits to {:ok, []} without any call" do
    assert LyricsChunker.chunk([]) == {:ok, []}
  end

  test "chunk/1 on a non-list input is a clear error, not a crash" do
    assert LyricsChunker.chunk(nil) == {:error, :invalid_script}
    assert LyricsChunker.chunk("not a list") == {:error, :invalid_script}
  end
end
