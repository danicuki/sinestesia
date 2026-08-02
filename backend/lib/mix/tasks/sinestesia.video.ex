defmodule Mix.Tasks.Sinestesia.Video do
  @shortdoc "Turn a performance video into the Sinestesia show it would have produced live"
  @moduledoc """
  Video in → video out: given a clip of someone singing, produce the video
  Sinestesia would have projected had it been running at that performance —
  same pipeline, same look-ahead/pre-render machinery, same reveal gating —
  composed with the original audio and the artist picture-in-picture.

      mix sinestesia.video ../take.mp4
      mix sinestesia.video ../take.mp4 --song-url https://www.letras.mus.br/toquinho/aquarela/
      mix sinestesia.video ../take.mp4 --session ../take-session.json --out /tmp/final.mp4

  The steps mirror the live flow exactly:

    1. transcribe the video's audio locally with word timings
       (tools/video_to_session.py — no cloud STT, no API key);
    2. find the song: the local library first (`SongLibrary.identify`, the
       same matcher the stage uses), then `SongId` + a lyrics-site import
       (letras.mus.br / cifraclub), VERIFIED against the transcript before
       being trusted, and saved into `SONGS_DIR` for next time;
    3. replay the session through the real pipeline — chunking, eager
       bootstrap, deep look-ahead, reveal-on-confirmation all live code;
    4. compose the revealed frames into a video: crossfades at the reveal
       instants, the artist PIP'd in a corner, the original audio underneath.

  ## Lead time

  On stage the song is loaded BEFORE the first note (during applause, a talk,
  an intro), which is what lets the pre-render buffer fill. A phone video
  starts at the first note. `--lead` (default 15s) shifts the session events
  later so the pipeline gets that same head start, and the composition shifts
  the reveal times back — the output timeline matches the performance, and
  the buffer behaves the way a real show's would.

  ## Options

      --session PATH    reuse an existing session JSON (skip transcription)
      --song-url URL    skip identification; import lyrics from this URL
      --style TEXT      visual style for the run
      --out PATH        output video (default: <video dir>/<name>-sinestesia.mp4)
      --fade MS         crossfade duration (default 1500, matching the stage)
      --lead S          pre-load head start in seconds (default 15)
      --pip POS         br|bl|tr|tl|off (default br)

  Provider selection stays with the environment (.env), same as every other
  entry point: DIRECTOR_PROVIDER / IMAGE_PROVIDER / OLLAMA_MODEL etc. For a
  fully-offline run: DIRECTOR_PROVIDER=gemma, LYRICS_CHUNK_ALLOW_LOCAL=1,
  SONGID_ALLOW_LOCAL=1, and any keyless IMAGE_PROVIDER.
  """
  use Mix.Task
  require Logger

  @impl true
  def run(args) do
    {video, opts} = parse_args(args)
    video = Path.expand(video)
    File.exists?(video) || Mix.raise("video not found: #{video}")

    fade_ms = opts[:fade] || 1_500
    lead_ms = round((opts[:lead] || 15.0) * 1_000)

    # ── 1. session (transcription) ─────────────────────────────────────────
    session = load_or_build_session(video, opts)
    transcript = session["events"] |> Enum.filter(& &1["final"]) |> Enum.map_join(" ", & &1["text"])
    Mix.shell().info("── transcript ──\n#{transcript}\n")

    # ── 2. song: library → identify → import → verify ──────────────────────
    # Needs the app for Req/SongId/SongLibrary; env must be set before boot.
    System.put_env("STT_PROVIDER", "replay")
    System.put_env("PORT", System.get_env("REPLAY_PORT", "4999"))
    Mix.Task.run("app.start")

    song = resolve_song(transcript, opts)
    Mix.shell().info("── song: #{song.title}#{if song.artist, do: " — #{song.artist}"} ──")

    # ── 3. replay through the real pipeline ────────────────────────────────
    enriched =
      session
      |> Map.put("lyrics_text", song.lyrics_text)
      |> Map.update("events", [], fn evs ->
        Enum.map(evs, &Map.update!(&1, "at_ms", fn t -> t + lead_ms end))
      end)
      |> then(fn s ->
        style = opts[:style] || song.style || s["style"]
        if style, do: Map.put(s, "style", style), else: s
      end)

    enriched_path = Path.join(System.tmp_dir!(), "sinestesia-video-#{session["name"]}.json")
    File.write!(enriched_path, Jason.encode!(enriched))
    System.put_env("REPLAY_FILE", enriched_path)
    System.put_env("REPLAY_SPEED", "1.0")

    duration_ms = enriched["events"] |> List.last() |> Map.fetch!("at_ms")
    deadline_ms = duration_ms + 45_000

    parent = self()
    socket = spawn(fn -> socket_loop(parent) end)
    {:ok, _pipeline} = Sinestesia.Pipeline.start_link(socket)

    frames_dir =
      Path.join(System.tmp_dir!(), "sinestesia-video-frames-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(frames_dir)

    fetcher = spawn_link(fn -> fetch_worker() end)

    Mix.shell().info("── replaying #{session["name"]} (#{length(enriched["events"])} events, lead #{div(lead_ms, 1000)}s) ──")

    acc =
      collect(deadline_ms, %{
        images: [],
        started_at: now_ms(),
        frames_dir: frames_dir,
        fetcher: fetcher
      })

    acc.images != [] || Mix.raise("no images were produced — check the provider env")

    # Drain the fetch queue; a frame whose download ultimately failed is
    # dropped (with its slot logged) rather than crashing the composition.
    send(fetcher, {:drain, self()})

    results =
      receive do
        {:fetched, results} -> results
      after
        300_000 -> Mix.raise("fetch worker did not drain in 5 minutes")
      end

    images =
      acc.images
      |> Enum.with_index(1)
      |> Enum.filter(fn {img, n} ->
        case Map.get(results, img.file) do
          :ok ->
            true

          other ->
            Mix.shell().error("frame #{n} download failed (#{inspect(other)}) — dropped")
            false
        end
      end)
      |> Enum.map(fn {img, _} ->
        # A morph is only usable whole: one missing subframe would make the
        # transition stutter, so any failure downgrades this image to the
        # synthetic-blend path rather than playing a gappy sequence.
        ok_subs = Enum.filter(img.subfiles, &(Map.get(results, &1) == :ok))

        if length(ok_subs) == length(img.subfiles),
          do: img,
          else: %{img | subfiles: []}
      end)

    images != [] || Mix.raise("every frame download failed — check the image provider")
    acc = %{acc | images: images}

    # ── 4. compose the final video ─────────────────────────────────────────
    out =
      opts[:out] ||
        Path.join(Path.dirname(video), "#{session["name"]}-sinestesia.mp4")

    compose(video, acc, lead_ms, fade_ms, opts[:pip] || "br", out)
    Mix.shell().info("\n── done ──\n#{out}")
  end

  # Strictly-serial download worker. Fetches queue in ITS mailbox while it
  # patiently retries the current one — so the rate-limited provider only
  # ever sees one request from us at a time, and a contended window (the
  # pipeline's own warm-up traffic during the replay) just delays the queue
  # instead of failing frames. `{:drain, from}` replies with a results map
  # once everything queued before it is done.
  defp fetch_worker(results \\ %{}) do
    receive do
      {:fetch, url, file} ->
        outcome =
          case fetch_image_retrying(url) do
            {:ok, {ext, body}} ->
              write_as_jpg(file, ext, body)
              :ok

            error ->
              error
          end

        fetch_worker(Map.put(results, file, outcome))

      {:drain, from} ->
        send(from, {:fetched, results})
    end
  end

  # ── session ──────────────────────────────────────────────────────────────

  defp load_or_build_session(video, opts) do
    case opts[:session] do
      nil ->
        root = Path.expand("..")
        py = Path.join(root, "tools/.venv/bin/python")

        # Transcription runs in tools/.venv regardless of backend; what it
        # needs installed differs. With ELEVENLABS_API_KEY set (the stage's
        # own account) it uses Scribe's batch endpoint and only needs
        # `requests`; with no key at all it falls to a local faster-whisper.
        # See tools/stt_batch.py — STT_PROVIDER selects the REALTIME engine
        # for the live show, and is honoured here too so an operator doesn't
        # have to configure the same thing twice.
        eleven? = (System.get_env("ELEVENLABS_API_KEY") || "") != ""

        deps =
          if eleven?,
            do: "requests",
            else: "faster-whisper"

        File.exists?(py) ||
          Mix.raise("""
          tools/.venv not found. Create it once with:

            uv venv --python 3.12 tools/.venv
            uv pip install --python tools/.venv/bin/python #{deps}

          (or: python3 -m venv tools/.venv && tools/.venv/bin/pip install #{deps})

          #{if eleven?,
            do: "ELEVENLABS_API_KEY is set, so Scribe's batch endpoint will be used — no local model needed.",
            else: "No ELEVENLABS_API_KEY found, so transcription runs on a local whisper. Set the key to use Scribe instead."}
          """)

        out_dir = Path.join(System.tmp_dir!(), "sinestesia-video")
        File.mkdir_p!(out_dir)

        {output, status} =
          System.cmd(py, [Path.join(root, "tools/video_to_session.py"), video, "--out", out_dir],
            stderr_to_stdout: true
          )

        status == 0 || Mix.raise("transcription failed:\n#{output}")
        Mix.shell().info(output)

        name = video |> Path.basename() |> Path.rootname() |> slugify()
        session_path = Path.join(out_dir, "#{name}.json")
        session_path |> File.read!() |> Jason.decode!()

      path ->
        path |> Path.expand() |> File.read!() |> Jason.decode!()
    end
  end

  # ── song resolution ──────────────────────────────────────────────────────

  defp resolve_song(transcript, opts) do
    cond do
      url = opts[:song_url] ->
        import_and_save(url, nil) ||
          Mix.raise("could not import lyrics from #{url}")

      match = library_hit(transcript) ->
        Mix.shell().info("[song] matched the local library: #{match.title}")
        match

      true ->
        identify_and_import(transcript)
    end
  end

  # The exact matcher the stage uses for SONG_AUTO_IDENTIFY, same 24-word cap.
  defp library_hit(transcript) do
    capped = transcript |> String.split() |> Enum.take(24) |> Enum.join(" ")

    case Sinestesia.SongLibrary.identify(capped) do
      {:match, song} -> song
      :no_match -> nil
    end
  end

  defp identify_and_import(transcript) do
    case Sinestesia.SongId.identify(transcript) do
      {:ok, %{title: title} = guess} when is_binary(title) ->
        Mix.shell().info("[songid] guessed: #{title} — #{guess.artist || "?"}")

        candidate_urls(guess)
        |> Enum.find_value(fn url -> import_and_save(url, transcript) end)
        |> case do
          nil ->
            Mix.raise("""
            couldn't import verified lyrics for "#{title}" (#{guess.artist || "?"}).
            Pass --song-url with a letras.mus.br / cifraclub.com.br link.
            """)

          song ->
            song
        end

      other ->
        Mix.raise("""
        song identification failed (#{inspect(other)}).
        Pass --song-url with a letras.mus.br / cifraclub.com.br link.
        """)
    end
  end

  # letras.mus.br first (simpler markup, per LyricsImport), cifraclub second.
  defp candidate_urls(%{title: title, artist: artist}) do
    t = slugify(title)

    case artist && slugify(artist) do
      nil -> []
      a -> ["https://www.letras.mus.br/#{a}/#{t}/", "https://www.cifraclub.com.br/#{a}/#{t}/letra/"]
    end
  end

  # Import, VERIFY against what was actually sung, then persist to SONGS_DIR
  # (the user-visible library — next run is a library hit, no network).
  #
  # The verification is not optional politeness: letras.mus.br redirects a
  # miss to a similarly-titled song (it once turned "Aquarela" into "Aquarela
  # do Brasil" — see songs/README), and SongId itself can guess wrong. The
  # check is the same overlap the live matcher uses: does the transcript's
  # opening actually appear in the imported lyrics?
  defp import_and_save(url, transcript) do
    case Sinestesia.LyricsImport.import(url) do
      {:ok, %{lyrics_text: lyrics} = imported} when is_binary(lyrics) and lyrics != "" ->
        if transcript == nil or verified?(transcript, lyrics) do
          title = imported.title || "Untitled"

          {:ok, song} =
            Sinestesia.SongLibrary.save(%{
              title: title,
              artist: imported.artist,
              source_url: url,
              lyrics_text: lyrics
            })

          Mix.shell().info("[import] saved to library: #{song.id} (#{url})")
          song
        else
          Mix.shell().info("[import] #{url} does NOT match the transcript — rejected")
          nil
        end

      {:error, reason} ->
        Mix.shell().info("[import] #{url}: #{inspect(reason)}")
        nil

      _ ->
        nil
    end
  end

  defp verified?(transcript, lyrics_text) do
    capped = transcript |> String.split() |> Enum.take(24) |> Enum.join(" ")
    lines = Sinestesia.PerformanceFollower.normalize(lyrics_text)

    Enum.any?(Enum.take(lines, 8), fn line ->
      Sinestesia.PerformanceFollower.covers?(capped, line)
    end)
  end

  # ── replay collection (same shape as mix sinestesia.replay) ──────────────

  defp socket_loop(parent) do
    receive do
      {:push_json, msg} -> send(parent, {:pushed, msg})
      _ -> :ok
    end

    socket_loop(parent)
  end

  defp collect(deadline_ms, acc) do
    remaining = deadline_ms - (now_ms() - acc.started_at)

    receive do
      {:pushed, %{type: "image"} = msg} ->
        n = length(acc.images) + 1
        # Reveal instant = when the PUSH arrives here. NOT msg.ts: the
        # pipeline stamps ts when the frame_msg is BUILT, which for held
        # frames (eager bootstrap, deep look-ahead) is render-finish time,
        # seconds before the reveal — using it put the opening frame on
        # screen before a single word had been sung. Nothing else in collect
        # blocks, so receive time IS push time.
        revealed_at = now_ms()
        at_s = Float.round((revealed_at - acc.started_at) / 1000, 1)
        Mix.shell().info("[#{String.pad_leading(to_string(n), 2, "0")}] +#{at_s}s  #{msg.prompt}")

        # Hand the downloads to the single fetch worker (collect must never
        # block, or later frames' receive-time timestamps shift). ONE worker,
        # strictly serial, because the failure mode here is precise:
        # Pollinations' anonymous tier allows ONE queued request per IP, and
        # our fetches compete with the pipeline's own warm-up HEADs during
        # the replay. Parallel fetches with retries still lost 3 frames of 6
        # to 429s on a live run; a serial queue with patient backoff drains
        # naturally once the replay's own traffic quiets down.
        pad_n = String.pad_leading(to_string(n), 2, "0")
        file = Path.join(acc.frames_dir, "frame_#{pad_n}.jpg")
        send(acc.fetcher, {:fetch, msg.url, file})

        # The sidecar's latent-morph subframes (LOCAL_MORPH) — the exact
        # transition the stage would have played into this image. Local URLs,
        # so these fetches are cheap; they queue behind the main frame.
        subfiles =
          msg
          |> Map.get(:frames, [])
          |> Kernel.||([])
          |> Enum.with_index(1)
          |> Enum.map(fn {sub_url, j} ->
            sub = Path.join(acc.frames_dir, "frame_#{pad_n}_m#{String.pad_leading(to_string(j), 2, "0")}.jpg")
            send(acc.fetcher, {:fetch, sub_url, sub})
            sub
          end)

        collect(deadline_ms, %{
          acc
          | images: acc.images ++ [%{revealed_at: revealed_at, file: file, subfiles: subfiles}]
        })

      {:pushed, %{type: "replay_done"}} ->
        Mix.shell().info("── playback done, waiting for trailing work ──")
        collect(min(deadline_ms, now_ms() - acc.started_at + 20_000), acc)

      {:pushed, _other} ->
        collect(deadline_ms, acc)
    after
      max(remaining, 0) -> acc
    end
  end

  # ── composition ──────────────────────────────────────────────────────────
  #
  # The image track is a concat of stills: each scene's transition window
  # [reveal, reveal+fade] plays the sidecar's REAL latent-morph subframes
  # when the run produced them (LOCAL_MORPH) — the exact frames the stage
  # would have played — and a synthesized linear blend otherwise; then the
  # final image holds until the next reveal. Black before the first reveal
  # (the live canvas is black until the first frame too). The artist video
  # is overlaid as PIP and provides the audio; total duration is the
  # performance's.

  defp compose(video, acc, lead_ms, fade_ms, pip, out) do
    audio_dur_ms = probe_duration_ms(video)

    # Reveal instants on the PERFORMANCE clock: the pipeline's push moment on
    # the replay clock, minus the artificial pre-load lead. A frame revealed
    # during the lead (eager bootstrap finishing early) clamps to 0 — on
    # stage it would have been holding, revealed at the first confirmed
    # words. A frame revealed AFTER the audio ends is dropped, not clamped
    # in: on the real stage that render would have landed after the song
    # too — showing it earlier would falsify the very timing this exists to
    # reproduce.
    frames =
      acc.images
      |> Enum.map(fn img ->
        %{
          at_ms: max(img.revealed_at - acc.started_at - lead_ms, 0),
          file: img.file,
          subfiles: img.subfiles
        }
      end)
      |> Enum.sort_by(& &1.at_ms)
      |> Enum.reject(fn f ->
        late = f.at_ms >= audio_dur_ms - 300
        if late, do: Mix.shell().info("[compose] dropping a frame revealed after the song ended")
        late
      end)
      # Monotonic, ≥ 100ms apart — two frames revealed in the same instant
      # would give a zero-length segment.
      |> Enum.scan(fn f, prev -> %{f | at_ms: max(f.at_ms, prev.at_ms + 100)} end)

    frames != [] || Mix.raise("every frame was revealed after the song ended — nothing to compose")
    {w, h} = probe_even_dims(List.first(frames).file)

    morphs = Enum.count(frames, &(&1.subfiles != []))

    Mix.shell().info(
      "── composing #{length(frames)} frames (#{morphs} with real morphs) → #{w}x#{h}, fade #{fade_ms}ms, pip #{pip} ──"
    )

    workdir = Path.dirname(List.first(frames).file)
    concat_path = build_concat(frames, fade_ms, audio_dur_ms, w, h, workdir)
    args = ffmpeg_args(video, concat_path, audio_dur_ms, w, h, pip, out)

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> Mix.raise("ffmpeg failed (#{status}):\n#{String.slice(output, -3000, 3000)}")
    end
  end

  # The image track as a concat-demuxer script: a sequence of stills with
  # durations. Every piece is normalized to the canvas first — the concat
  # demuxer requires uniform dimensions, and the bootstrap frame (cloud t2i)
  # can differ in size from the sidecar's morph subframes.
  defp build_concat(frames, fade_ms, audio_dur_ms, w, h, workdir) do
    black = Path.join(workdir, "black.jpg")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i color=c=black:s=#{w}x#{h} -frames:v 1) ++ [black],
        stderr_to_stdout: true
      )

    n = length(frames)

    pieces =
      frames
      |> Enum.with_index()
      |> Enum.flat_map(fn {f, i} ->
        next_at = if i + 1 < n, do: Enum.at(frames, i + 1).at_ms, else: audio_dur_ms
        prev_file = if i == 0, do: black, else: Enum.at(frames, i - 1).file

        # The transition can never outlive its own slot: a rapid-fire reveal
        # (two scenes in one breath) shortens the fade rather than overrunning
        # the next scene's start.
        fade = min(fade_ms, next_at - f.at_ms)

        transition =
          case f.subfiles do
            [] ->
              # No sidecar morph for this boundary (bootstrap t2i, provider
              # fallback): synthesize the stage's crossfade as 12 linear
              # blends, the same recipe mix sinestesia.replay exports.
              blend_steps(prev_file, f.file, i, 12, workdir)

            subs ->
              Enum.map(subs, &norm(&1, w, h, workdir))
          end

        per = fade / length(transition) / 1000

        transition_pieces = Enum.map(transition, &{&1, per})
        hold = (next_at - f.at_ms - fade) / 1000

        transition_pieces ++
          if hold > 0.001, do: [{norm(f.file, w, h, workdir), hold}], else: []
      end)

    first_at = List.first(frames).at_ms
    pieces = if first_at > 0, do: [{black, first_at / 1000} | pieces], else: pieces

    # Last line repeats the final still with no duration — concat-demuxer
    # convention so the stream doesn't end a frame early.
    {last_file, _} = List.last(pieces)

    script =
      pieces
      |> Enum.flat_map(fn {file, dur} ->
        ["file '#{file}'", "duration #{Float.round(dur, 3)}"]
      end)
      |> Kernel.++(["file '#{last_file}'"])
      |> Enum.join("\n")

    path = Path.join(workdir, "concat.txt")
    File.write!(path, script <> "\n")
    path
  end

  # Scale+pad a still to the canvas, cached by basename (subframes are
  # reused nowhere, finals are reused as hold pieces).
  defp norm(file, w, h, workdir) do
    out = Path.join(workdir, "norm_#{Path.basename(file)}")

    if not File.exists?(out) do
      {_, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-y", "-v", "error", "-i", file,
            "-vf",
            "scale=#{w}:#{h}:force_original_aspect_ratio=decrease," <>
              "pad=#{w}:#{h}:(ow-iw)/2:(oh-ih)/2:black,setsar=1",
            "-q:v", "2", out
          ],
          stderr_to_stdout: true
        )
    end

    out
  end

  defp blend_steps(from_file, to_file, boundary, steps, workdir) do
    {w, h} = probe_even_dims(to_file)
    from_n = norm(from_file, w, h, workdir)
    to_n = norm(to_file, w, h, workdir)

    1..steps
    |> Enum.map(fn j ->
      t = :erlang.float_to_binary(j / (steps + 1), decimals: 4)
      out = Path.join(workdir, "blend_#{boundary}_#{String.pad_leading(to_string(j), 2, "0")}.jpg")

      {_, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-y", "-v", "error", "-i", from_n, "-i", to_n,
            "-filter_complex", "blend=all_expr='A*(1-#{t})+B*#{t}'",
            "-frames:v", "1", out
          ],
          stderr_to_stdout: true
        )

      out
    end)
    |> Kernel.++([to_n])
  end

  defp ffmpeg_args(video, concat_path, audio_dur_ms, _w, h, pip, out) do
    total_s = Float.round(audio_dur_ms / 1000, 3)

    pip_filters =
      case pip do
        "off" ->
          ["[imgs]copy[outv]"]

        pos ->
          ph = div(h, 3)
          margin = 24

          {x, y} =
            case pos do
              "br" -> {"W-w-#{margin}", "H-h-#{margin}"}
              "bl" -> {"#{margin}", "H-h-#{margin}"}
              "tr" -> {"W-w-#{margin}", "#{margin}"}
              "tl" -> {"#{margin}", "#{margin}"}
            end

          [
            "[1:v]scale=-2:#{ph},setsar=1[pip]",
            "[imgs][pip]overlay=#{x}:#{y}:shortest=0[outv]"
          ]
      end

    filtergraph = Enum.join(["[0:v]setsar=1,fps=30[imgs]"] ++ pip_filters, ";")

    [
      "-y",
      "-f", "concat", "-safe", "0", "-i", concat_path,
      "-i", video,
      "-filter_complex", filtergraph,
      "-map", "[outv]", "-map", "1:a",
      "-t", Float.to_string(total_s),
      "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast", "-crf", "21",
      "-c:a", "aac", "-b:a", "192k",
      out
    ]
  end

  # ── small helpers (same shapes as mix sinestesia.replay) ─────────────────

  defp probe_duration_ms(path) do
    {out, 0} =
      System.cmd("ffprobe", [
        "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", path
      ])

    {sec, _} = Float.parse(String.trim(out))
    round(sec * 1000)
  end

  defp probe_even_dims(image) do
    {out, 0} =
      System.cmd("ffprobe", [
        "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
        "-of", "csv=s=x:p=0", image
      ])

    [w, h] = out |> String.trim() |> String.split("x") |> Enum.map(&String.to_integer/1)
    {w - rem(w, 2), h - rem(h, 2)}
  end

  # Free image hosts rate-limit hard (Pollinations anonymous tier: max ONE
  # queued request per IP) and their CDN can 5xx transiently — and for
  # URL-triggers-generation providers the fetch IS the render, so a failure
  # here is a lost frame, worth several patient retries with backoff.
  defp fetch_image_retrying(url, tries \\ 7, backoff_ms \\ 4_000) do
    case fetch_image(url) do
      {:ok, _} = ok ->
        ok

      {:error, reason} when tries > 1 ->
        Mix.shell().info("[fetch] #{inspect(reason)}; retrying in #{div(backoff_ms, 1000)}s")
        Process.sleep(backoff_ms)
        fetch_image_retrying(url, tries - 1, min(backoff_ms * 2, 20_000))

      error ->
        error
    end
  end

  defp fetch_image("data:image/" <> rest) do
    [meta, b64] = String.split(rest, ",", parts: 2)
    ext = if String.starts_with?(meta, "jpeg"), do: "jpg", else: "png"
    {:ok, {ext, Base.decode64!(b64)}}
  end

  defp fetch_image(url) do
    ext = if String.contains?(url, ".jpg"), do: "jpg", else: "png"

    case Req.get(url, retry: false, decode_body: false, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, {ext, body}}
      {:ok, %{status: status}} -> {:error, {:bad_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_as_jpg(dest, "jpg", body), do: File.write!(dest, body)

  defp write_as_jpg(dest, _ext, body) do
    tmp = dest <> ".tmp.png"
    File.write!(tmp, body)

    try do
      {_, 0} = System.cmd("ffmpeg", ["-y", "-v", "error", "-i", tmp, "-q:v", "2", dest])
    after
      File.rm(tmp)
    end
  end

  defp slugify(s) do
    s
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp parse_args(args) do
    case OptionParser.parse(args,
           strict: [
             session: :string,
             song_url: :string,
             style: :string,
             out: :string,
             fade: :integer,
             lead: :float,
             pip: :string
           ]
         ) do
      {opts, [video], []} ->
        {video, opts}

      _ ->
        Mix.raise(
          "usage: mix sinestesia.video <video> [--session S] [--song-url URL] " <>
            "[--style S] [--out PATH] [--fade MS] [--lead S] [--pip br|bl|tr|tl|off]"
        )
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
