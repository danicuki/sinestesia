defmodule Sinestesia.SongLibraryTest do
  use ExUnit.Case, async: false
  alias Sinestesia.SongLibrary

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "sinestesia_songs_test_#{System.unique_integer([:positive])}")

    prev = System.get_env("SONGS_DIR")
    System.put_env("SONGS_DIR", tmp)

    on_exit(fn ->
      File.rm_rf(tmp)
      if prev, do: System.put_env("SONGS_DIR", prev), else: System.delete_env("SONGS_DIR")
    end)

    %{dir: tmp}
  end

  test "save/1 persists a song and get/1 reads it back" do
    assert {:ok, saved} =
             SongLibrary.save(%{
               title: "Aquarela",
               artist: "Toquinho",
               lyrics_text: "Numa folha qualquer\neu desenho um sol amarelo"
             })

    assert saved.id == "aquarela"
    assert saved.artist == "Toquinho"
    assert String.ends_with?(saved.added_at, "Z") or saved.added_at =~ "T"

    fetched = SongLibrary.get("aquarela")
    assert fetched.title == "Aquarela"
    assert fetched.lyrics_text =~ "Numa folha qualquer"
  end

  test "save/1 requires a title" do
    assert {:error, :title_required} = SongLibrary.save(%{artist: "Nobody"})
  end

  test "get/1 on an unknown id returns nil" do
    assert SongLibrary.get("does-not-exist") == nil
  end

  test "list/0 returns id/title/artist for every saved song, sorted by title" do
    SongLibrary.save(%{title: "Zebra Song", lyrics_text: "z"})
    SongLibrary.save(%{title: "Aquarela", artist: "Toquinho", lyrics_text: "a"})

    assert [%{title: "Aquarela", artist: "Toquinho"}, %{title: "Zebra Song"}] = SongLibrary.list()
  end

  test "save/1 upserts — saving the same id again overwrites, doesn't duplicate" do
    SongLibrary.save(%{title: "Aquarela", lyrics_text: "v1"})
    SongLibrary.save(%{title: "Aquarela", lyrics_text: "v2"})

    assert length(SongLibrary.list()) == 1
    assert SongLibrary.get("aquarela").lyrics_text == "v2"
  end

  test "delete/1 removes a song; is idempotent" do
    SongLibrary.save(%{title: "Aquarela", lyrics_text: "a"})
    assert SongLibrary.get("aquarela") != nil

    assert :ok = SongLibrary.delete("aquarela")
    assert SongLibrary.get("aquarela") == nil
    # Deleting again (already gone) must not error.
    assert :ok = SongLibrary.delete("aquarela")
  end

  test "an explicit id overrides the title-derived slug" do
    {:ok, saved} = SongLibrary.save(%{id: "custom-id", title: "Aquarela", lyrics_text: "a"})
    assert saved.id == "custom-id"
    assert SongLibrary.get("custom-id") != nil
    assert SongLibrary.get("aquarela") == nil
  end

  describe "identify/2" do
    setup do
      SongLibrary.save(%{
        title: "Aquarela",
        lyrics_text: "Numa folha qualquer eu desenho um sol amarelo\nE com cinco ou seis retas"
      })

      SongLibrary.save(%{
        title: "Fly Me To The Moon",
        lyrics_text:
          "Fly me to the moon and let me play among the stars\nLet me see what spring is like"
      })

      :ok
    end

    test "matches a song from just its opening words" do
      assert {:match, %{title: "Aquarela"}} =
               SongLibrary.identify("Numa folha qualquer eu desenho um sol amarelo")

      assert {:match, %{title: "Fly Me To The Moon"}} =
               SongLibrary.identify("Fly me to the moon and let me play among the stars")
    end

    test "tolerates a couple of STT substitutions/omissions" do
      assert {:match, %{title: "Aquarela"}} =
               SongLibrary.identify("numa folha qualquer desenho um sol amarelo")
    end

    test "an unrelated phrase matches nothing — never guesses wrong just to guess" do
      assert :no_match = SongLibrary.identify("completely unrelated words about something else")
    end

    test "an empty library (or empty input) never matches" do
      SongLibrary.delete("aquarela")
      SongLibrary.delete("fly-me-to-the-moon")
      assert :no_match = SongLibrary.identify("Numa folha qualquer eu desenho um sol amarelo")
    end
  end
end
