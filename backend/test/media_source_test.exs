defmodule Sinestesia.MediaSourceTest do
  # async: false — these tests swap PATH to point System.cmd at shim
  # executables, and PATH is VM-global.
  use ExUnit.Case, async: false

  alias Sinestesia.MediaSource

  describe "url?/1" do
    test "URLs are URLs" do
      assert MediaSource.url?("https://www.youtube.com/watch?v=abc123")
      assert MediaSource.url?("http://youtu.be/abc123")
    end

    test "paths are not" do
      refute MediaSource.url?("../take.mp4")
      refute MediaSource.url?("/home/x/video.mp4")
      refute MediaSource.url?("httpsish-name.mp4")
    end
  end

  # ── shim harness ──────────────────────────────────────────────────────────
  # A shim dir replaces PATH entirely: find_executable sees exactly the tools
  # the test installs, and System.cmd runs them. Each shim logs its argv so
  # the test can assert what was asked of the real tool.

  defp with_shims(shims, fun) do
    dir = Path.join(System.tmp_dir!(), "shims-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for {name, script} <- shims do
      path = Path.join(dir, name)
      File.write!(path, "#!/bin/sh\n" <> script)
      File.chmod!(path, 0o755)
    end

    old_path = System.get_env("PATH")
    # /bin:/usr/bin stay: the shims are /bin/sh scripts.
    System.put_env("PATH", Enum.join([dir, "/bin", "/usr/bin"], ":"))

    try do
      fun.(dir)
    after
      System.put_env("PATH", old_path)
    end
  end

  defp tmp_out do
    dir = Path.join(System.tmp_dir!(), "media-out-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  describe "download/2" do
    test "happy path: audio file + title from the info json" do
      out = tmp_out()

      shim = """
      echo "$@" > "#{out}/argv"
      out=""
      while [ $# -gt 1 ]; do
        if [ "$1" = "-o" ]; then out="$2"; fi
        shift
      done
      dir=$(dirname "$out")
      printf x > "$dir/source.m4a"
      printf '{"title": "Aquarela (Ao Vivo)"}' > "$dir/source.info.json"
      """

      with_shims([{"yt-dlp", shim}], fn _ ->
        assert {:ok, %{audio: audio, title: "Aquarela (Ao Vivo)"}} =
                 MediaSource.download("https://youtu.be/abc", out)

        assert File.exists?(audio)
        argv = File.read!(Path.join(out, "argv"))
        assert argv =~ "--no-playlist"
        assert argv =~ "--audio-format m4a"
        assert argv =~ "https://youtu.be/abc"

        assert File.exists?(Path.join(out, "download.done")),
               "a completed download must leave the cache marker"
      end)
    end

    test "a completed download is served from cache without invoking the tool" do
      out = tmp_out()
      File.write!(Path.join(out, "source.m4a"), "x")
      File.write!(Path.join(out, "source.info.json"), ~s({"title": "Dinda"}))
      File.write!(Path.join(out, "download.done"), "")

      # The shim would fail loudly — the cache hit must never reach it.
      with_shims([{"yt-dlp", "echo BOOM; exit 1"}], fn _ ->
        assert {:ok, %{title: "Dinda"}} = MediaSource.download("https://youtu.be/abc", out)
      end)
    end

    test "files without the marker are a killed run, not a cache" do
      out = tmp_out()
      # Audio present but no marker: the previous run died mid-write.
      File.write!(Path.join(out, "source.m4a"), "partial")

      with_shims([{"yt-dlp", "echo BOOM; exit 1"}], fn _ ->
        assert {:error, {:yt_dlp_failed, 1, _}} = MediaSource.download("https://youtu.be/abc", out)
      end)
    end

    test "a run that produces no audio is an error, not a mystery" do
      out = tmp_out()

      with_shims([{"yt-dlp", "exit 0"}], fn _ ->
        assert {:error, {:download_produced_no_audio, _}} =
                 MediaSource.download("https://youtu.be/abc", out)
      end)
    end

    test "tool failure carries the tool's own output" do
      out = tmp_out()

      with_shims([{"yt-dlp", "echo 'ERROR: Video unavailable'; exit 1"}], fn _ ->
        assert {:error, {:yt_dlp_failed, 1, msg}} = MediaSource.download("https://youtu.be/x", out)
        assert msg =~ "Video unavailable"
        refute msg =~ "HINT", "the EJS hint must not fire on unrelated failures"
      end)
    end

    test "a missing-JS-runtime failure names the real cause and the fix" do
      out = tmp_out()

      # The 2026 EJS failure shape: challenge solving fails, then YouTube's
      # misleading "not available" — the video exists, the signature didn't
      # resolve. The error must say what to install, not just relay the lie.
      shim =
        "echo 'WARNING: [youtube] x: n challenge solving failed: Some formats may be missing.'; " <>
          "echo 'ERROR: [youtube] x: This video is not available'; exit 1"

      with_shims([{"yt-dlp", shim}], fn _ ->
        assert {:error, {:yt_dlp_failed, 1, msg}} = MediaSource.download("https://youtu.be/x", out)
        assert msg =~ "HINT"
        assert msg =~ "deno"
        assert msg =~ "yt-dlp[default]"
      end)
    end

    test "missing tool names the install command" do
      out = tmp_out()

      with_shims([], fn _ ->
        assert {:error, {:tool_missing, "yt-dlp", hint}} =
                 MediaSource.download("https://youtu.be/x", out)

        assert hint =~ "install it with"
      end)
    end
  end

  describe "separate_vocals/2" do
    test "finds vocals.wav wherever the demucs version put it" do
      out = tmp_out()

      # The model-name path segment varies across Demucs versions — the shim
      # uses a deliberately unexpected one to prove the glob doesn't assume.
      shim = """
      echo "$@" > "#{out}/argv"
      mkdir -p "#{out}/htdemucs_ft/source"
      printf x > "#{out}/htdemucs_ft/source/vocals.wav"
      """

      with_shims([{"demucs", shim}], fn _ ->
        assert {:ok, vocals} = MediaSource.separate_vocals("/x/source.m4a", out)
        assert String.ends_with?(vocals, "htdemucs_ft/source/vocals.wav")

        argv = File.read!(Path.join(out, "argv"))
        assert argv =~ "--two-stems=vocals"
        assert argv =~ "-d cpu"

        assert File.exists?(Path.join(out, "vocals.done")),
               "a completed separation must leave the cache marker"
      end)
    end

    test "a completed separation is served from cache without invoking the tool" do
      out = tmp_out()
      File.mkdir_p!(Path.join(out, "htdemucs/source"))
      File.write!(Path.join(out, "htdemucs/source/vocals.wav"), "x")
      File.write!(Path.join(out, "vocals.done"), "")

      with_shims([{"demucs", "echo BOOM; exit 1"}], fn _ ->
        assert {:ok, vocals} = MediaSource.separate_vocals("/x/source.m4a", out)
        assert String.ends_with?(vocals, "htdemucs/source/vocals.wav")
      end)
    end

    test "a stem without the marker is a killed run, not a cache" do
      out = tmp_out()
      File.mkdir_p!(Path.join(out, "htdemucs/source"))
      File.write!(Path.join(out, "htdemucs/source/vocals.wav"), "partial")

      with_shims([{"demucs", "echo BOOM; exit 1"}], fn _ ->
        assert {:error, {:demucs_failed, 1, _}} = MediaSource.separate_vocals("/x/source.m4a", out)
      end)
    end

    test "DEMUCS_DEVICE reaches the tool" do
      out = tmp_out()
      System.put_env("DEMUCS_DEVICE", "mps")
      on_exit(fn -> System.delete_env("DEMUCS_DEVICE") end)

      shim = """
      echo "$@" > "#{out}/argv"
      mkdir -p "#{out}/m/t"
      printf x > "#{out}/m/t/vocals.wav"
      """

      with_shims([{"demucs", shim}], fn _ ->
        assert {:ok, _} = MediaSource.separate_vocals("/x/a.m4a", out)
        assert File.read!(Path.join(out, "argv")) =~ "-d mps"
      end)
    end

    test "a clean exit with no vocals is still an error" do
      out = tmp_out()

      with_shims([{"demucs", "exit 0"}], fn _ ->
        assert {:error, {:demucs_produced_no_vocals, _}} =
                 MediaSource.separate_vocals("/x/a.m4a", out)
      end)
    end
  end
end
