defmodule Mix.Tasks.Sinestesia.VideoLibraryHitTest do
  # async: false — SONGS_DIR is process-environment-global.
  use ExUnit.Case, async: false

  # The exact failure from the first real YouTube run (2026-08-04): whisper
  # transcribed the studio mix's opening as "Uma folha é qualquer" instead of
  # "Numa folha qualquer" — enough token damage to miss the live matcher's
  # threshold, upon which the local SongId hallucinated a different song
  # entirely. The batch flow must rescue this via verification, because it
  # holds what the stage doesn't: the full transcript.
  @batch_transcript "Uma folha é qualquer, eu desenho um sol amarelo E com cinco ou seis retas é fácil fazer um castelo Com um lápis em tomo da mão imitou uma luva E se faço chover com dois riscos tem um guarda -chuva"

  setup do
    dir = Path.join(System.tmp_dir!(), "songs-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # The REAL library file, verbatim — a hand-tuned fixture scored above the
    # strict threshold and silently stopped exercising the loose pass, which
    # is the entire point of this test.
    File.cp!(Path.expand("../songs/aquarela.json", File.cwd!()), Path.join(dir, "aquarela.json"))

    System.put_env("SONGS_DIR", dir)
    on_exit(fn -> System.delete_env("SONGS_DIR") end)
    :ok
  end

  test "a degraded batch transcript still hits the library via verification" do
    hit = Mix.Tasks.Sinestesia.Video.library_hit(@batch_transcript)
    assert hit, "loose pass + covers? verification should rescue this transcript"
    assert hit.title == "Aquarela"
  end

  test "the source title rescues when even the loose matcher misses" do
    # Mangle the opening beyond the loose threshold's reach…
    mangled = "la la la la coisa nenhuma castelo amarelo " <> @batch_transcript

    # …but the rest of the transcript still covers real lines, so the title
    # hint may accept — and only with that verification.
    hit = Mix.Tasks.Sinestesia.Video.library_hit(mangled, "MÚSICA AQUARELA ORIGINAL TOQUINHO")
    assert hit
    assert hit.title == "Aquarela"
  end

  test "a title hint for a DIFFERENT performance is refused" do
    off_script = "letra completamente diferente sem relação nenhuma com a canção da biblioteca em nada"

    refute Mix.Tasks.Sinestesia.Video.library_hit(off_script, "MÚSICA AQUARELA ORIGINAL TOQUINHO"),
           "a title match without transcript verification must never identify a song"
  end

  test "an unrelated transcript with no hint stays a miss" do
    refute Mix.Tasks.Sinestesia.Video.library_hit("asa branca quando olhei a terra ardendo")
  end
end
