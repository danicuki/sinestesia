defmodule Sinestesia.PipelineSongLibraryTest do
  @moduledoc """
  Pipeline integration for Sinestesia.SongLibrary: load_song/list_songs/
  save_song wiring, auto-identification from a few sung words, and setlist
  auto-advance on a completed song. Uses a temp SONGS_DIR per test so this
  never touches the real repo `songs/` directory.
  """
  use ExUnit.Case, async: false

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "sinestesia_songs_pipeline_#{System.unique_integer([:positive])}"
      )

    prev = %{
      songs_dir: System.get_env("SONGS_DIR"),
      stt: System.get_env("STT_PROVIDER"),
      look: System.get_env("SPECULATIVE_LOOKAHEAD"),
      auto_id: System.get_env("SONG_AUTO_IDENTIFY")
    }

    System.put_env("SONGS_DIR", tmp)
    System.put_env("STT_PROVIDER", "replay")
    System.delete_env("REPLAY_FILE")
    System.delete_env("SPECULATIVE_LOOKAHEAD")
    System.delete_env("SONG_AUTO_IDENTIFY")

    {:ok, pid} = Sinestesia.Pipeline.start_link(self())

    on_exit(fn ->
      File.rm_rf(tmp)
      restore("SONGS_DIR", prev.songs_dir)
      restore("STT_PROVIDER", prev.stt)
      restore("SPECULATIVE_LOOKAHEAD", prev.look)
      restore("SONG_AUTO_IDENTIFY", prev.auto_id)

      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end)

    %{pid: pid}
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, val), do: System.put_env(key, val)

  defp sing(pid, text), do: send(pid, {:transcript, :replay, text, true, 0})

  describe "list_songs / load_song" do
    test "list_songs pushes the catalog", %{pid: pid} do
      Sinestesia.SongLibrary.save(%{title: "Aquarela", artist: "Toquinho", lyrics_text: "a"})

      Sinestesia.Pipeline.list_songs(pid)
      assert_receive {:push_json, %{type: "songs", songs: [%{title: "Aquarela"}]}}
    end

    test "load_song loads its lyrics and tracks current_song_id", %{pid: pid} do
      Sinestesia.SongLibrary.save(%{
        title: "Aquarela",
        artist: "Toquinho",
        lyrics_text: "Numa folha qualquer\neu desenho um sol amarelo"
      })

      Sinestesia.Pipeline.load_song(pid, "aquarela")

      assert_receive {:push_json, %{type: "song_loaded", id: "aquarela", title: "Aquarela"}}
      state = :sys.get_state(pid)
      assert state.current_song_id == "aquarela"
      assert state.script_active? == true
      assert "Numa folha qualquer" in state.script
    end

    test "load_song with a pinned style applies it before loading lyrics", %{pid: pid} do
      Sinestesia.SongLibrary.save(%{
        title: "Aquarela",
        lyrics_text: "a\nb",
        style: "watercolor and ink, pale washes"
      })

      Sinestesia.Pipeline.load_song(pid, "aquarela")
      assert_receive {:push_json, %{type: "style", style: "watercolor and ink, pale washes"}}
      assert_receive {:push_json, %{type: "song_loaded"}}

      state = :sys.get_state(pid)
      assert state.style == "watercolor and ink, pale washes"
    end

    test "load_song for an unknown id reports an error, doesn't crash", %{pid: pid} do
      Sinestesia.Pipeline.load_song(pid, "does-not-exist")
      assert_receive {:push_json, %{type: "song_error"}}
      assert :sys.get_state(pid).current_song_id == nil
    end
  end

  describe "save_song" do
    test "saves the currently loaded script as a new song when no lyrics_text is given", %{
      pid: pid
    } do
      Sinestesia.Pipeline.set_lyrics(pid, "Fly me to the moon\nlet me play among the stars")

      Sinestesia.Pipeline.save_song(pid, %{"title" => "Fly Me To The Moon", "artist" => "Sinatra"})

      assert_receive {:push_json, %{type: "song_saved", title: "Fly Me To The Moon"}}

      saved = Sinestesia.SongLibrary.get("fly-me-to-the-moon")
      assert saved.artist == "Sinatra"
      assert saved.lyrics_text =~ "Fly me to the moon"
    end

    test "an explicit lyrics_text overrides the current script", %{pid: pid} do
      Sinestesia.Pipeline.save_song(pid, %{"title" => "Custom", "lyrics_text" => "explicit text"})
      assert_receive {:push_json, %{type: "song_saved"}}
      assert Sinestesia.SongLibrary.get("custom").lyrics_text == "explicit text"
    end
  end

  describe "auto-identification (SONG_AUTO_IDENTIFY)" do
    setup do
      Sinestesia.SongLibrary.save(%{
        title: "Aquarela",
        lyrics_text: "Numa folha qualquer eu desenho um sol amarelo\nE com cinco ou seis retas"
      })

      :ok
    end

    test "off by default: singing a known song's opening does NOT auto-load it", %{pid: pid} do
      sing(pid, "Numa folha qualquer eu desenho um sol amarelo")
      state = :sys.get_state(pid)
      assert state.script_active? == false
      assert state.current_song_id == nil
    end

    test "on: singing a known opening identifies and loads it mid-stream", %{pid: pid} do
      System.put_env("SONG_AUTO_IDENTIFY", "on")

      sing(pid, "Numa folha qualquer eu desenho um sol amarelo")

      assert_receive {:push_json, %{type: "song_identified", title: "Aquarela"}}
      state = :sys.get_state(pid)
      assert state.current_song_id == "aquarela"
      assert state.script_active? == true
    end

    test "on: an unrelated improvisation never auto-loads anything", %{pid: pid} do
      System.put_env("SONG_AUTO_IDENTIFY", "on")

      sing(pid, "some completely unrelated improvised words")

      state = :sys.get_state(pid)
      refute state.script_active?
      assert state.current_song_id == nil
    end

    test "only attempts once — once a script is active it doesn't re-run every line", %{pid: pid} do
      System.put_env("SONG_AUTO_IDENTIFY", "on")
      sing(pid, "Numa folha qualquer eu desenho um sol amarelo")
      assert_receive {:push_json, %{type: "song_identified"}}

      # Load something else manually afterward — auto-identify must not fight
      # a manually loaded script by re-running on the next line.
      Sinestesia.Pipeline.set_lyrics(pid, "totally different lyrics\nsecond line")
      sing(pid, "second line")

      state = :sys.get_state(pid)
      assert state.script == ["totally different lyrics", "second line"]
    end
  end

  describe "setlist" do
    setup do
      Sinestesia.SongLibrary.save(%{title: "Song One", lyrics_text: "one a\none b"})
      Sinestesia.SongLibrary.save(%{title: "Song Two", lyrics_text: "two a\ntwo b"})
      :ok
    end

    test "load_setlist loads the FIRST song immediately", %{pid: pid} do
      Sinestesia.Pipeline.load_setlist(pid, ["song-one", "song-two"])

      assert_receive {:push_json, %{type: "song_loaded", id: "song-one", setlist_index: 0}}
      state = :sys.get_state(pid)
      assert state.current_song_id == "song-one"
      assert state.setlist == ["song-one", "song-two"]
    end

    test "end_song advances to the NEXT setlist entry", %{pid: pid} do
      Sinestesia.Pipeline.load_setlist(pid, ["song-one", "song-two"])
      assert_receive {:push_json, %{type: "song_loaded", id: "song-one"}}

      Sinestesia.Pipeline.end_song(pid, %{})
      assert_receive {:push_json, %{type: "mint_error"}}
      assert_receive {:push_json, %{type: "song_loaded", id: "song-two", setlist_index: 1}}

      state = :sys.get_state(pid)
      assert state.current_song_id == "song-two"
      assert state.setlist_index == 1
    end

    test "a plain reset_song (discard) does NOT advance the setlist", %{pid: pid} do
      Sinestesia.Pipeline.load_setlist(pid, ["song-one", "song-two"])
      assert_receive {:push_json, %{type: "song_loaded", id: "song-one"}}

      Sinestesia.Pipeline.reset_song(pid)

      state = :sys.get_state(pid)
      assert state.setlist_index == 0
      assert state.script == ["one a", "one b"]
    end

    test "advancing past the last song leaves state as-is, doesn't crash", %{pid: pid} do
      Sinestesia.Pipeline.load_setlist(pid, ["song-one"])
      assert_receive {:push_json, %{type: "song_loaded", id: "song-one"}}

      Sinestesia.Pipeline.end_song(pid, %{})
      assert_receive {:push_json, %{type: "mint_error"}}
      refute_receive {:push_json, %{type: "song_loaded"}}, 200

      assert :sys.get_state(pid).current_song_id == "song-one"
    end
  end
end
