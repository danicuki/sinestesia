defmodule Mix.Tasks.Sinestesia.VideoTranscriptFallbackTest do
  use ExUnit.Case, async: true

  # The exact situation from the first real run against an original song
  # (2026-08-04, "Dinda"): no lyrics page exists anywhere, so the transcript
  # itself must become the lyric sheet instead of the task aborting.

  test "finals become the lyric sheet, with stanza breaks on long pauses" do
    session = %{
      "events" => [
        %{"final" => true, "text" => "Queria que a verdade fosse como um fruto", "at_ms" => 1_000},
        %{"final" => true, "text" => "que a gente alcançasse a qualquer minuto", "at_ms" => 4_000},
        %{"final" => false, "text" => "felicidade mo", "at_ms" => 9_000},
        %{"final" => true, "text" => "Felicidade mora logo atrás do muro", "at_ms" => 12_000}
      ]
    }

    song = Mix.Tasks.Sinestesia.Video.transcript_song(session, nil)

    assert song.lyrics_text ==
             "Queria que a verdade fosse como um fruto\n" <>
               "que a gente alcançasse a qualquer minuto\n" <>
               "\nFelicidade mora logo atrás do muro"
  end

  test "a long sung line with no pause is NOT a stanza break" do
    # Finals are stamped at phrase END, so these two finals are 7s apart —
    # but the partial at 4.8s shows singing resumed after only 0.8s of
    # silence. Distance-based logic would break here; silence-based must not.
    session = %{
      "events" => [
        %{"final" => true, "text" => "primeira frase", "at_ms" => 4_000},
        %{"final" => false, "text" => "uma-", "at_ms" => 4_800},
        %{"final" => true, "text" => "uma frase comprida cantada sem parar", "at_ms" => 11_000}
      ]
    }

    song = Mix.Tasks.Sinestesia.Video.transcript_song(session, nil)
    assert song.lyrics_text == "primeira frase\numa frase comprida cantada sem parar"
  end

  test "the source title is a naming hint, never an artist guess" do
    session = %{"events" => [%{"final" => true, "text" => "la la la", "at_ms" => 0}]}

    song = Mix.Tasks.Sinestesia.Video.transcript_song(session, "Daniella Alcarpe - Dinda")
    assert song.title == "Daniella Alcarpe - Dinda"
    assert song.artist == nil
    assert song.style == nil
  end

  test "no hint stays Untitled, per the on-chain honesty rule" do
    session = %{"events" => [%{"final" => true, "text" => "la la la", "at_ms" => 0}]}
    assert Mix.Tasks.Sinestesia.Video.transcript_song(session, nil).title == "Untitled"
  end
end
