defmodule Mix.Tasks.Sinestesia.VideoSessionCacheTest do
  use ExUnit.Case, async: true

  alias Sinestesia.MediaSource

  # The per-URL cache exists so test iterations (--style/--motion/--limit)
  # only re-pay generation, never download/separation/transcription.

  test "cache_dir is deterministic per URL and records the URL for humans" do
    url = "https://youtu.be/test-#{:erlang.unique_integer([:positive])}"
    dir = MediaSource.cache_dir(url)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert MediaSource.cache_dir(url) == dir
    assert File.read!(Path.join(dir, "source.url")) == url <> "\n"
    refute MediaSource.cache_dir(url <> "x") == dir
  end

  test "session cache keys on provider and lang; local files have none" do
    media = %{cache: "/c", compose: "x", stt: "y", title: nil, has_video?: false}

    assert Mix.Tasks.Sinestesia.Video.session_cache_path(media, stt_provider: :elevenlabs) ==
             "/c/session-elevenlabs-auto.json"

    assert Mix.Tasks.Sinestesia.Video.session_cache_path(media,
             stt_provider: :local_whisper,
             lang: "pt"
           ) == "/c/session-local_whisper-pt.json"

    local = %{media | cache: nil}
    assert Mix.Tasks.Sinestesia.Video.session_cache_path(local, stt_provider: :elevenlabs) == nil
  end

  test "a cached transcription is loaded without touching STT" do
    dir = Path.join(System.tmp_dir!(), "sess-cache-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    session = %{"name" => "dinda", "events" => [%{"at_ms" => 1, "final" => true, "text" => "la"}]}
    File.write!(Path.join(dir, "session-elevenlabs-auto.json"), Jason.encode!(session))

    media = %{cache: dir, compose: "x", stt: "y", title: nil, has_video?: false}

    # No STT provider is reachable in tests — reaching one would crash, so
    # success here IS the proof the cache short-circuited.
    assert Mix.Tasks.Sinestesia.Video.load_or_build_session(media, stt_provider: :elevenlabs) ==
             session
  end

  test "an explicit --session wins over the cache" do
    dir = Path.join(System.tmp_dir!(), "sess-cache-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "session-elevenlabs-auto.json"), ~s({"name": "cached"}))
    explicit = Path.join(dir, "mine.json")
    File.write!(explicit, ~s({"name": "explicit"}))

    media = %{cache: dir, compose: "x", stt: "y", title: nil, has_video?: false}

    assert Mix.Tasks.Sinestesia.Video.load_or_build_session(media,
             session: explicit,
             stt_provider: :elevenlabs
           ) == %{"name" => "explicit"}
  end
end
