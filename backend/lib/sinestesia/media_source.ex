defmodule Sinestesia.MediaSource do
  @moduledoc """
  Resolves the source medium for `mix sinestesia.video`.

  A local file passes straight through. A URL is fetched with `yt-dlp`
  (audio only — the YouTube flow has no PIP, so the picture is never
  needed). A full mix can then have its vocal stem isolated with Demucs,
  so the batch STT hears a clean voice instead of a band — the same
  reason `tools/song_to_session.py` separates first: word timestamps off
  a full mix are noticeably worse, and a bad transcript poisons song
  identification downstream.

  Both tools are external programs invoked like ffmpeg is everywhere else
  in this codebase. Neither is bundled: the error messages name the
  install command instead of the exception.

      DEMUCS_DEVICE   torch device for separation (default: cpu;
                      set `mps` on Apple Silicon — it is several times faster)
  """
  require Logger

  @doc "Is this argument a URL rather than a local path?"
  @spec url?(String.t()) :: boolean()
  def url?(arg), do: String.match?(arg, ~r{^https?://})

  @doc """
  The persistent cache directory for a URL's downloaded/derived media.

  Keyed by the URL's hash under the OS user-cache dir (XDG-aware via
  `:filename.basedir/2`), so a song processed once is never re-downloaded,
  re-separated or re-transcribed on later runs — `/tmp` dies on reboot and
  those three steps are the slow/paid part of every test iteration.
  `mix sinestesia.video --fresh` wipes one URL's entry.
  """
  @spec cache_dir(String.t()) :: Path.t()
  def cache_dir(url) do
    key = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    dir = Path.join(:filename.basedir(:user_cache, "sinestesia"), "media-#{key}")
    File.mkdir_p!(dir)

    # The hash is for the filesystem; the URL is for the human wondering
    # what this cache entry holds.
    url_file = Path.join(dir, "source.url")
    File.exists?(url_file) || File.write!(url_file, url <> "\n")
    dir
  end

  @doc """
  Download the audio track of `url` into `out_dir`.

  Returns `{:ok, %{audio: path, title: title | nil}}`. The title comes from
  the platform metadata (yt-dlp's info JSON) and is only a naming hint —
  song identity is still resolved from the TRANSCRIPT by the same
  library/SongId/import path the live stage uses, because video titles lie
  ("cover", "ao vivo", emoji, channel names) in exactly the ways that would
  poison an on-chain record.
  """
  @spec download(String.t(), Path.t()) :: {:ok, %{audio: Path.t(), title: String.t() | nil}} | {:error, term()}
  def download(url, out_dir) do
    File.mkdir_p!(out_dir)
    audio = Path.join(out_dir, "source.m4a")
    done = Path.join(out_dir, "download.done")

    # The marker, not the file, is what says "complete": a killed run can
    # leave a partial-looking tree, and a partial download fed to Demucs
    # would waste minutes before failing strangely.
    if File.exists?(done) and File.exists?(audio) do
      Logger.info("[media] using cached audio: #{audio} (--fresh to re-download)")
      {:ok, %{audio: audio, title: read_title(Path.join(out_dir, "source.info.json"))}}
    else
      run_download(url, out_dir, audio, done)
    end
  end

  defp run_download(url, out_dir, audio, done) do
    with :ok <- ensure_tool("yt-dlp", "brew install yt-dlp  (or: pipx install yt-dlp)") do
      template = Path.join(out_dir, "source.%(ext)s")

      args = [
        "--no-playlist",
        "-x",
        "--audio-format", "m4a",
        "--write-info-json",
        "-o", template,
        url
      ]

      Logger.info("[media] downloading audio: #{url}")

      case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
        {_, 0} ->
          if File.exists?(audio) do
            File.write!(done, "")
            {:ok, %{audio: audio, title: read_title(Path.join(out_dir, "source.info.json"))}}
          else
            {:error, {:download_produced_no_audio, out_dir}}
          end

        {out, status} ->
          {:error, {:yt_dlp_failed, status, String.slice(out, -800, 800) <> ejs_hint(out)}}
      end
    end
  end

  # YouTube's signature/n-parameter challenges are solved by an EXTERNAL JS
  # runtime since yt-dlp's EJS split — a box without one gets a misleading
  # "This video is not available" even though the video exists. Name the
  # real cause and the fix; the operator at the sound desk can't chase a
  # wiki link mid-setup.
  defp ejs_hint(out) do
    if out =~ ~r/challenge solving failed|jsruntime|yt-dlp\/wiki\/EJS/i do
      "\n\nHINT: yt-dlp needs a JavaScript runtime + solver scripts to unlock " <>
        "YouTube formats. Fix: `brew install deno` (or apt install deno) and " <>
        "reinstall yt-dlp with the solver: `uv tool install --force \"yt-dlp[default]\"`."
    else
      ""
    end
  end

  @doc """
  Isolate the vocal stem of `audio` with Demucs (two-stems mode).

  Returns the path to `vocals.wav`. Demucs writes to
  `<out>/<model>/<track>/vocals.wav`, so the result is globbed rather than
  assumed — the model name in the path changes across Demucs versions.
  """
  @spec separate_vocals(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def separate_vocals(audio, out_dir) do
    done = Path.join(out_dir, "vocals.done")

    # Demucs is the slowest step of a URL run (minutes on CPU) and its
    # output for the same audio never changes — the marker gates the cache
    # because a killed run leaves a partial vocals.wav in place.
    case {File.exists?(done), Path.wildcard(Path.join(out_dir, "*/*/vocals.wav"))} do
      {true, [vocals | _]} ->
        Logger.info("[media] using cached vocal stem: #{vocals} (--fresh to re-separate)")
        {:ok, vocals}

      _ ->
        run_separate(audio, out_dir, done)
    end
  end

  defp run_separate(audio, out_dir, done) do
    with :ok <- ensure_tool("demucs", "pipx install demucs  (or: pip install demucs)") do
      device = System.get_env("DEMUCS_DEVICE", "cpu")
      Logger.info("[media] isolating vocals with demucs (device: #{device}) — first run downloads the model")

      args = ["--two-stems=vocals", "-d", device, "-o", out_dir, audio]

      case System.cmd("demucs", args, stderr_to_stdout: true) do
        {_, 0} ->
          case Path.wildcard(Path.join(out_dir, "*/*/vocals.wav")) do
            [vocals | _] ->
              File.write!(done, "")
              {:ok, vocals}

            [] ->
              {:error, {:demucs_produced_no_vocals, out_dir}}
          end

        {out, status} ->
          {:error, {:demucs_failed, status, String.slice(out, -800, 800)}}
      end
    end
  end

  defp ensure_tool(bin, install_hint) do
    if System.find_executable(bin),
      do: :ok,
      else: {:error, {:tool_missing, bin, "install it with: #{install_hint}"}}
  end

  defp read_title(info_json) do
    with {:ok, raw} <- File.read(info_json),
         {:ok, %{"title" => title}} when is_binary(title) <- Jason.decode(raw) do
      title
    else
      _ -> nil
    end
  end
end
