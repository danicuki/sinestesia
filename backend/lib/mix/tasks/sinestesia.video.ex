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
      mix sinestesia.video https://www.youtube.com/watch?v=XXXXXXX

  ## YouTube (or any yt-dlp-supported URL)

  Given a URL instead of a file, the input is a *finished recording* rather
  than a camera take: the audio is downloaded (`yt-dlp`), the vocal stem is
  isolated (`demucs --two-stems=vocals` — batch STT on a clean voice beats
  STT on a full mix, same reason `tools/song_to_session.py` separates
  first), the session is transcribed from the VOCALS, and the final video is
  composed over the ORIGINAL full mix. There is no artist footage, so there
  is no PIP. Everything between — identification, lyrics import, chunking,
  the replay through the real pipeline — is the same code path as a camera
  take. `DEMUCS_DEVICE=mps` makes separation several times faster on Apple
  Silicon; `--no-separate` skips Demucs and transcribes the full mix.

  The steps mirror the live flow exactly:

    1. transcribe the video's audio with word timings
       (`Sinestesia.BatchStt` — the same providers and keys the stage uses,
       picked by the same STT_PROVIDER; falls back to the local-whisper
       sidecar when there is no key at all);
    2. find the song: the local library first (`SongLibrary.identify`, the
       same matcher the stage uses), then `SongId` + a lyrics-site import
       (letras.mus.br / cifraclub), VERIFIED against the transcript before
       being trusted, and saved into `SONGS_DIR` for next time. When nothing
       verifiable exists online — an original, an unreleased song — the
       transcription itself becomes the lyric sheet: the predictive stack
       then follows the transcript, which for a finished recording matches
       the performance exactly. It is NOT saved to the library (STT text is
       not verified lyrics); pass `--song-url` to use a real page instead;
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

  ## Motion mode (--motion): living scenes instead of stills

  The same mechanics — same pipeline, same reveals, same timing — but every
  scene window becomes a generated VIDEO clip (fal MiniMax H3): scene N's
  clip opens exactly on scene N's image, revealed on its line, and its
  final frame IS scene N+1's image, arriving at the next reveal. Adjacent
  clips share their boundary frame, so the song plays as one continuous
  living shot. `Sinestesia.MotionDirector` directs each shot's motion —
  camera, action, transformation — from the whole song's scene list; the
  image Director's stills become the chain's keyframe anchors.

  This is PAID inference (per generated second — see the rates in
  `Sinestesia.VideoGen.FalMinimax`): the task prints the total estimate and
  asks before submitting (`--yes` skips the prompt). A failed clip degrades
  that one window to the held still, never the song.

  ## Options

      --session PATH    reuse an existing session JSON (skip transcription)
      --song-url URL    skip identification; import lyrics from this URL
      --style TEXT      visual style for the run
      --out PATH        output video (default: <video dir>/<name>-sinestesia.mp4)
      --fade MS         crossfade duration (default 1500, matching the stage)
      --lead S          pre-load head start in seconds (default 15)
      --pip POS         br|bl|tr|tl|off (default br; forced off for URLs)
      --stt PROVIDER    elevenlabs|local_whisper (default: STT_PROVIDER)
      --lang CODE       ISO language for transcription (default: auto-detect)
      --no-separate     URL flow: skip Demucs, transcribe the full mix
      --motion          living-scene mode (paid fal MiniMax clips, see above)
      --motion-model M  h3-max (default) | h3
      --motion-resolution R  480P | 768P (default; h3 also 2K | 4K)
      --yes             skip the motion-mode cost confirmation

  Provider selection stays with the environment (.env), same as every other
  entry point: DIRECTOR_PROVIDER / IMAGE_PROVIDER / OLLAMA_MODEL etc. For a
  fully-offline run: DIRECTOR_PROVIDER=gemma, LYRICS_CHUNK_ALLOW_LOCAL=1,
  SONGID_ALLOW_LOCAL=1, and any keyless IMAGE_PROVIDER.

  One deliberate exception: the predictive stack (SPECULATIVE_LOOKAHEAD=on,
  LOOKAHEAD_DEPTH=3, MUSICAL_STRUCTURE=on) defaults ON here even though the
  stage treats it as opt-in — this task's entire purpose is the ideal show,
  and without look-ahead every frame is reactive and lands seconds late.
  Your .env or shell still wins if either sets those variables.
  """
  use Mix.Task
  require Logger

  @impl true
  def run(args) do
    {input, opts} = parse_args(args)

    input =
      if Sinestesia.MediaSource.url?(input) do
        input
      else
        path = Path.expand(input)
        File.exists?(path) || Mix.raise("video not found: #{path}")
        path
      end

    fade_ms = opts[:fade] || 1_500
    lead_ms = round((opts[:lead] || 15.0) * 1_000)

    # Boot FIRST. Two things depend on it and both bit us: Req/Finch has to be
    # running before any HTTP call, and `config/runtime.exs` is what loads
    # `.env` into the process environment — so reading STT_PROVIDER or
    # ELEVENLABS_API_KEY before this point sees an operator's .env as empty
    # and silently falls back to the local sidecar.
    #
    # PORT is set beforehand because the supervisor binds it at boot; the
    # replay override of STT_PROVIDER is NOT, both because runtime.exs lets a
    # pre-set variable win over .env (which would hide the real choice) and
    # because nothing reads it until Pipeline.start_link below.
    System.put_env("PORT", System.get_env("REPLAY_PORT", "4999"))
    Mix.Task.run("app.start")

    # The point of this task is the show the stage WOULD have produced, and
    # the stage runs the predictive stack — lyrics look-ahead, deep
    # pre-render, structure hints. Without it every frame is reactive and
    # lands ~2-3s after its line, which is precisely the timing this task
    # exists to avoid. Defaults are applied AFTER app.start so an operator's
    # .env (loaded by runtime.exs) or shell still wins.
    for {k, v} <- %{
          "SPECULATIVE_LOOKAHEAD" => "on",
          "LOOKAHEAD_DEPTH" => "3",
          "MUSICAL_STRUCTURE" => "on"
        },
        System.get_env(k) == nil do
      System.put_env(k, v)
    end

    stt =
      case opts[:stt] do
        nil -> Sinestesia.BatchStt.provider()
        name -> String.to_existing_atom(name)
      end

    # ── 0. resolve the medium (after boot: .env holds DEMUCS_DEVICE) ───────
    # `compose` is what the final video's audio comes from; `stt` is what the
    # transcription hears. For a camera take they are the same file. For a
    # URL they differ: compose keeps the original full mix, stt gets the
    # isolated vocal stem.
    media = resolve_media(input, opts)

    # ── 1. session (transcription) ─────────────────────────────────────────
    session = load_or_build_session(media, Keyword.put(opts, :stt_provider, stt))
    transcript = session["events"] |> Enum.filter(& &1["final"]) |> Enum.map_join(" ", & &1["text"])
    Mix.shell().info("── transcript ──\n#{transcript}\n")

    # ── 2. song: library → identify → import → verify ──────────────────────

    song = resolve_song(session, transcript, media.title, opts)
    Mix.shell().info("── song: #{song.title}#{if song.artist, do: " — #{song.artist}"} ──")

    # ── 3. replay through the real pipeline ────────────────────────────────
    style = opts[:style] || song.style || session["style"]

    enriched =
      session
      |> Map.put("lyrics_text", song.lyrics_text)
      |> Map.update("events", [], fn evs ->
        Enum.map(evs, &Map.update!(&1, "at_ms", fn t -> t + lead_ms end))
      end)
      |> then(fn s -> if style, do: Map.put(s, "style", style), else: s end)

    # From here on the pipeline drives itself off the recorded session.
    System.put_env("STT_PROVIDER", "replay")

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
    out = opts[:out] || default_out(media, session["name"])

    pip =
      cond do
        not media.has_video? and opts[:pip] not in [nil, "off"] ->
          Mix.shell().info("[compose] --pip ignored: a URL source has no artist footage")
          "off"

        not media.has_video? ->
          "off"

        true ->
          opts[:pip] || "br"
      end

    if opts[:motion] do
      compose_motion(media.compose, acc, lead_ms, pip, out, style, opts)
    else
      compose(media.compose, acc, lead_ms, fade_ms, pip, out)
    end

    Mix.shell().info("\n── done ──\n#{out}")
  end

  # ── media resolution ─────────────────────────────────────────────────────

  defp resolve_media(input, opts) do
    if Sinestesia.MediaSource.url?(input) do
      out_dir = Path.join(System.tmp_dir!(), "sinestesia-video-dl-#{:erlang.phash2(input)}")

      %{audio: audio, title: title} =
        case Sinestesia.MediaSource.download(input, out_dir) do
          {:ok, dl} -> dl
          {:error, reason} -> Mix.raise("download failed: #{format_tool_error(reason)}")
        end

      if title, do: Mix.shell().info("── source: #{title} ──")

      stt_media =
        if opts[:no_separate] do
          Mix.shell().info("[media] --no-separate: transcribing the full mix")
          audio
        else
          case Sinestesia.MediaSource.separate_vocals(audio, out_dir) do
            {:ok, vocals} ->
              vocals

            {:error, reason} ->
              Mix.raise("""
              vocal separation failed: #{format_tool_error(reason)}
              (re-run with --no-separate to transcribe the full mix instead)
              """)
          end
        end

      %{compose: audio, stt: stt_media, title: title, has_video?: false}
    else
      %{compose: input, stt: input, title: nil, has_video?: true}
    end
  end

  defp format_tool_error({:tool_missing, bin, hint}), do: "#{bin} not found — #{hint}"
  defp format_tool_error(other), do: inspect(other)

  # A camera take's output lands next to the take; a URL's "directory" is a
  # tmp download dir nobody will look in, so the output lands in cwd.
  defp default_out(%{has_video?: true, compose: video}, name),
    do: Path.join(Path.dirname(video), "#{name}-sinestesia.mp4")

  defp default_out(_media, name), do: Path.expand("#{name}-sinestesia.mp4")

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

  defp load_or_build_session(media, opts) do
    case opts[:session] do
      nil ->
        out_dir = Path.join(System.tmp_dir!(), "sinestesia-video")

        stt_opts = [lang: opts[:lang] || "", provider: opts[:stt_provider]]

        case Sinestesia.BatchStt.session_from_video(media.stt, out_dir, stt_opts) do
          {:ok, session} ->
            # The session transcribed the STT medium (a vocal stem, for a
            # URL), but everything downstream that touches "audio" or the
            # name must see the PERFORMANCE: the original mix, named after
            # the source title — "vocals" is what the file is, not what the
            # song is.
            session
            |> Map.put("audio", Path.expand(media.compose))
            |> then(fn s ->
              if media.title, do: Map.put(s, "name", slugify(media.title)), else: s
            end)

          {:error, reason} ->
            Mix.raise("transcription failed: #{inspect(reason)}")
        end

      path ->
        path |> Path.expand() |> File.read!() |> Jason.decode!()
    end
  end

  # ── song resolution ──────────────────────────────────────────────────────

  defp resolve_song(session, transcript, title_hint, opts) do
    cond do
      url = opts[:song_url] ->
        import_and_save(url, nil) ||
          Mix.raise("could not import lyrics from #{url}")

      match = library_hit(transcript, title_hint) ->
        Mix.shell().info("[song] matched the local library: #{match.title}")
        match

      song = identify_and_import(transcript) ->
        song

      true ->
        # An original or unreleased song has no lyrics page anywhere — that
        # can't be a fatal error for a task whose input is arbitrary
        # recordings. The transcription IS an accurate lyric sheet for this
        # exact recording (it came from this audio), so the look-ahead will
        # follow it near-perfectly; what it can't carry is a verified
        # title/artist, so those stay a naming hint and nil rather than a
        # guess (SongId's rejected guess is NOT reused here).
        Mix.shell().info(
          "[song] no verified lyrics found online — using the transcription itself " <>
            "as the lyric sheet (pass --song-url to import from a lyrics page instead)"
        )

        transcript_song(session, title_hint)
    end
  end

  # Batch STT of a studio mix mangles words the live mic doesn't ("Numa
  # folha" → "Uma folha é"), which eats the margin under the live matcher's
  # threshold. Unlike the stage, this flow holds the WHOLE transcript — so a
  # looser second pass is allowed exactly when the same covers? verification
  # that gates lyric imports confirms it, and the source title (URL flow)
  # gets a third, equally-verified pass. A candidate that fails verification
  # is treated as no hit at all, never a soft yes.
  @loose_threshold 0.5

  @doc false
  # Public for tests; not part of any API.
  def library_hit(transcript, title_hint \\ nil) do
    capped = transcript |> String.split() |> Enum.take(24) |> Enum.join(" ")

    strict =
      case Sinestesia.SongLibrary.identify(capped) do
        {:match, song} -> song
        :no_match -> nil
      end

    loose = fn ->
      case Sinestesia.SongLibrary.identify(capped, threshold: @loose_threshold) do
        {:match, song} -> if verified?(transcript, song.lyrics_text), do: song
        :no_match -> nil
      end
    end

    by_title = fn ->
      if title_hint do
        Sinestesia.SongLibrary.list()
        |> Enum.map(&Sinestesia.SongLibrary.get(&1.id))
        |> Enum.reject(&is_nil/1)
        |> Enum.find(fn song ->
          String.contains?(slugify(title_hint), slugify(song.title)) and
            verified?(transcript, song.lyrics_text)
        end)
      end
    end

    strict || loose.() || by_title.()
  end

  defp identify_and_import(transcript) do
    case Sinestesia.SongId.identify(transcript) do
      {:ok, %{title: title} = guess} when is_binary(title) ->
        Mix.shell().info("[songid] guessed: #{title} — #{guess.artist || "?"}")

        candidate_urls(guess)
        |> Enum.find_value(fn url -> import_and_save(url, transcript) end)
        |> tap(fn
          nil ->
            Mix.shell().info(
              "[song] no page for \"#{title}\" (#{guess.artist || "?"}) survived transcript verification"
            )

          _song ->
            :ok
        end)

      other ->
        Mix.shell().info("[song] identification failed (#{inspect(other)})")
        nil
    end
  end

  # A pause long enough to read as an instrumental break becomes a stanza
  # boundary — that's what MusicalStructure sections on, and the pauses are
  # real (they're in the recording), unlike any guess about verse/chorus.
  # The pause is the SILENCE, not the final-to-final distance: a final's
  # at_ms is the END of its phrase (BatchStt stamps `w.end`), so consecutive
  # finals are always a whole sung line apart. The first partial after a
  # final is (one word into) the next phrase's start — that minus the
  # previous final's end is the silence.
  @stanza_gap_ms 4_000

  @doc false
  # Public for tests; not part of any API.
  def transcript_song(session, title_hint) do
    {rev_lines, _prev_end, _start} =
      Enum.reduce(session["events"], {[], nil, nil}, fn ev, {lines, prev_end, start} ->
        start = start || ev["at_ms"]

        if ev["final"] do
          gap? = prev_end != nil and start - prev_end > @stanza_gap_ms
          {[if(gap?, do: "\n" <> ev["text"], else: ev["text"]) | lines], ev["at_ms"], nil}
        else
          {lines, prev_end, start}
        end
      end)

    %{
      title: title_hint || "Untitled",
      artist: nil,
      style: nil,
      lyrics_text: rev_lines |> Enum.reverse() |> Enum.join("\n")
    }
  end

  # The SITE's search first — slug guesses are a trap (letras localizes
  # "Simon & Garfunkel" to /simon-e-garfunkel/, unguessable from the name).
  # The guessed URLs stay as fallback for when the search is unreachable,
  # and every candidate still has to pass transcript verification.
  defp candidate_urls(%{title: title, artist: artist}) do
    searched = Sinestesia.LyricsImport.LetrasComBr.search("#{title} #{artist}")

    t = slugify(title)

    guessed =
      case artist && slugify(artist) do
        nil -> []
        a -> ["https://www.letras.mus.br/#{a}/#{t}/", "https://www.cifraclub.com.br/#{a}/#{t}/letra/"]
      end

    Enum.uniq(searched ++ guessed)
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
          | images:
              acc.images ++
                [%{revealed_at: revealed_at, file: file, subfiles: subfiles, prompt: msg.prompt}]
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

  # Reveal instants on the PERFORMANCE clock: the pipeline's push moment on
  # the replay clock, minus the artificial pre-load lead. A frame revealed
  # during the lead (eager bootstrap finishing early) clamps to 0 — on
  # stage it would have been holding, revealed at the first confirmed
  # words. A frame revealed AFTER the audio ends is dropped, not clamped
  # in: on the real stage that render would have landed after the song
  # too — showing it earlier would falsify the very timing this exists to
  # reproduce.
  defp timeline(acc, lead_ms, audio_dur_ms) do
    acc.images
    |> Enum.map(fn img ->
      %{
        at_ms: max(img.revealed_at - acc.started_at - lead_ms, 0),
        file: img.file,
        subfiles: img.subfiles,
        prompt: img.prompt
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
  end

  defp compose(video, acc, lead_ms, fade_ms, pip, out) do
    audio_dur_ms = probe_duration_ms(video)
    frames = timeline(acc, lead_ms, audio_dur_ms)
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

  # ── motion composition (--motion) ────────────────────────────────────────
  #
  # The living-scene chain: scene N's clip OPENS on scene N's anchor image
  # (revealed exactly on its line — same timing honesty as the still path)
  # and its FINAL frame is scene N+1's anchor, arriving precisely at the
  # next reveal. Consecutive clips share their boundary frame by
  # construction, so the whole song is one continuous camera. Because each
  # clip is pinned at both ends, all clips generate in PARALLEL — the chain
  # is in the shared anchors, not in sequential rendering. The last scene
  # has no destination and drifts freely to the song's end.
  #
  # Any clip that fails (refusal, queue error) degrades THAT window to the
  # held still — one lost scene must never lose the song.
  defp compose_motion(video, acc, lead_ms, pip, out, style, opts) do
    audio_dur_ms = probe_duration_ms(video)
    frames = timeline(acc, lead_ms, audio_dur_ms)
    frames != [] || Mix.raise("every frame was revealed after the song ended — nothing to compose")
    {w, h} = probe_even_dims(List.first(frames).file)
    workdir = Path.dirname(List.first(frames).file)

    model_name = opts[:motion_model] || "h3-max"

    model =
      Sinestesia.VideoGen.FalMinimax.model(model_name) ||
        Mix.raise("unknown --motion-model #{model_name} (#{Enum.join(Sinestesia.VideoGen.FalMinimax.models(), " | ")})")

    resolution = opts[:motion_resolution] || "768P"

    rate =
      Map.get(model.rates, resolution) ||
        Mix.raise("#{model_name} has no #{resolution} (options: #{Enum.join(Map.keys(model.rates), " | ")})")

    n = length(frames)

    scenes =
      frames
      |> Enum.with_index()
      |> Enum.map(fn {f, i} ->
        next = Enum.at(frames, i + 1)

        %{
          index: i,
          window_ms: (if next, do: next.at_ms, else: audio_dur_ms) - f.at_ms,
          from: f.file,
          to: next && next.file,
          prompt: f.prompt
        }
      end)

    durations =
      Enum.map(scenes, &Sinestesia.VideoGen.FalMinimax.clamp_duration(&1.window_ms / 1000))

    total_gen_s = Enum.sum(durations)
    cost = Float.round(total_gen_s * rate, 2)

    promo =
      if model.promo, do: " (launch promo pricing — roughly double after it ends)", else: ""

    Mix.shell().info(
      "── motion: #{n} scenes, #{total_gen_s}s of #{model_name} #{resolution} ≈ $#{cost}#{promo} ──"
    )

    opts[:yes] || Mix.shell().yes?("Generate #{n} clips on fal.ai (paid)?") ||
      Mix.raise("aborted — rerun without --motion for the still composition")

    directions = Sinestesia.MotionDirector.direct(style, Enum.map(scenes, & &1.prompt))

    # Normalize every anchor BEFORE the parallel fan-out: norm/4 writes to a
    # shared path and scene N's `to` is scene N+1's `from` — two tasks
    # racing to create the same file would corrupt both clips' keyframe.
    normed = Map.new(frames, fn f -> {f.file, norm(f.file, w, h, workdir)} end)

    clips =
      scenes
      |> Enum.zip(Enum.zip(directions, durations))
      |> Task.async_stream(
        fn {scene, {direction, duration}} ->
          generate_clip(scene, direction, duration, normed, workdir,
            model: model_name,
            resolution: resolution,
            style_suffix: style
          )
        end,
        timeout: :infinity,
        ordered: true,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    live = Enum.count(clips, & &1)

    live > 0 ||
      Mix.raise("every clip failed — check the fal dashboard; rerun without --motion for stills")

    if live < n,
      do: Mix.shell().info("[motion] #{n - live} of #{n} clips failed — those windows hold stills")

    segments =
      Enum.zip(scenes, clips)
      |> Enum.map(fn {scene, clip} -> motion_segment(scene, clip, normed, w, h, workdir) end)

    first_at = List.first(frames).at_ms

    segments =
      if first_at > 0,
        do: [black_segment(first_at, w, h, workdir) | segments],
        else: segments

    Mix.shell().info("── composing #{live}/#{n} living scenes → #{w}x#{h}, pip #{pip} ──")

    concat_path = Path.join(workdir, "concat_motion.txt")
    File.write!(concat_path, Enum.map_join(segments, "\n", &"file '#{&1}'") <> "\n")

    args = ffmpeg_args(video, concat_path, audio_dur_ms, w, h, pip, out)

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> Mix.raise("ffmpeg failed (#{status}):\n#{String.slice(output, -3000, 3000)}")
    end
  end

  defp generate_clip(scene, direction, duration, normed, workdir, opts) do
    prompt = if s = opts[:style_suffix], do: "#{direction}. #{s}", else: direction
    dest = Path.join(workdir, "clip_#{String.pad_leading(to_string(scene.index), 2, "0")}.mp4")

    submit_opts = [
      to: scene.to && Map.fetch!(normed, scene.to),
      duration: duration,
      resolution: opts[:resolution],
      model: opts[:model]
    ]

    with {:ok, request_url} <-
           Sinestesia.VideoGen.FalMinimax.submit(prompt, Map.fetch!(normed, scene.from), submit_opts),
         {:ok, path} <- Sinestesia.VideoGen.FalMinimax.await(request_url, dest) do
      Mix.shell().info("[motion] scene #{scene.index} clip ready")
      path
    else
      {:error, reason} ->
        Mix.shell().error("[motion] scene #{scene.index} clip failed: #{inspect(reason)}")
        nil
    end
  end

  # One uniform rule instead of hold/speed cases: the clip is retimed to
  # fill its scene window exactly, so its final frame lands ON the next
  # reveal. Extreme factors (a 3s window from a 5s minimum clip, a long
  # instrumental hold) degrade to fast/slow drift rather than breaking the
  # reveal grid; the factor is logged when it's far from 1.
  @doc false
  # Public for tests; not part of any API.
  def motion_segment(scene, clip, normed, w, h, workdir) do
    window_s = scene.window_ms / 1000
    seg = Path.join(workdir, "seg_#{String.pad_leading(to_string(scene.index), 2, "0")}.mp4")

    case clip do
      nil ->
        still_segment(Map.fetch!(normed, scene.from), window_s, seg)

      clip ->
        clip_s = probe_duration_ms(clip) / 1000
        factor = window_s / clip_s

        if factor < 0.5 or factor > 2.0 do
          Mix.shell().info(
            "[motion] scene #{scene.index}: retiming #{Float.round(clip_s, 1)}s clip into a " <>
              "#{Float.round(window_s, 1)}s window (#{Float.round(factor, 2)}x)"
          )
        end

        {_, 0} =
          System.cmd(
            "ffmpeg",
            [
              "-y", "-v", "error", "-i", clip,
              "-vf",
              "setpts=#{:erlang.float_to_binary(factor, decimals: 6)}*PTS," <>
                "scale=#{w}:#{h}:force_original_aspect_ratio=decrease," <>
                "pad=#{w}:#{h}:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=30",
              "-t", :erlang.float_to_binary(window_s, decimals: 3),
              "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "21",
              "-pix_fmt", "yuv420p", seg
            ],
            stderr_to_stdout: true
          )

        seg
    end
  end

  defp still_segment(still, window_s, seg) do
    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-y", "-v", "error", "-loop", "1", "-i", still,
          "-t", :erlang.float_to_binary(window_s, decimals: 3),
          "-vf", "fps=30,setsar=1",
          "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "21",
          "-pix_fmt", "yuv420p", seg
        ],
        stderr_to_stdout: true
      )

    seg
  end

  defp black_segment(dur_ms, w, h, workdir) do
    seg = Path.join(workdir, "seg_black.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-y", "-v", "error", "-f", "lavfi",
          "-i", "color=c=black:s=#{w}x#{h}:d=#{:erlang.float_to_binary(dur_ms / 1000, decimals: 3)}",
          "-r", "30", "-c:v", "libx264", "-preset", "veryfast", "-crf", "21",
          "-pix_fmt", "yuv420p", seg
        ],
        stderr_to_stdout: true
      )

    seg
  end

  # The image track as a concat-demuxer script: a sequence of stills with
  # durations. Every piece is normalized to the canvas first — the concat
  # demuxer requires uniform dimensions, and the bootstrap frame (cloud t2i)
  # can differ in size from the sidecar's morph subframes.
  @doc false
  # Public for tests; not part of any API.
  def build_concat(frames, fade_ms, audio_dur_ms, w, h, workdir) do
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
              # Blends happen ON THE CANVAS — providers like Gemini return
              # different dimensions per generation (1376x768 one frame,
              # 1408x768 the next), and ffmpeg's blend filter refuses
              # mismatched inputs.
              blend_steps(prev_file, f.file, i, 12, w, h, workdir)

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

  # Scale+pad a still to the canvas. The cache key MUST carry the target
  # dimensions: keying by basename alone once returned a 1376x768 cached
  # normalization when 1408x768 was asked for, and ffmpeg's blend filter
  # crashed the whole composition on the mismatch.
  defp norm(file, w, h, workdir) do
    out = Path.join(workdir, "norm_#{w}x#{h}_#{Path.basename(file)}")

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

  defp blend_steps(from_file, to_file, boundary, steps, w, h, workdir) do
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
             pip: :string,
             stt: :string,
             lang: :string,
             no_separate: :boolean,
             motion: :boolean,
             motion_model: :string,
             motion_resolution: :string,
             yes: :boolean
           ]
         ) do
      {opts, [video], []} ->
        {video, opts}

      _ ->
        Mix.raise(
          "usage: mix sinestesia.video <video-or-url> [--session S] [--song-url URL] " <>
            "[--style S] [--out PATH] [--fade MS] [--lead S] [--pip br|bl|tr|tl|off] " <>
            "[--stt elevenlabs|local_whisper] [--lang CODE] [--no-separate]"
        )
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
