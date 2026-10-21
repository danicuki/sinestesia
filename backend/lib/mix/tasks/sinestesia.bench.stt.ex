defmodule Mix.Tasks.Sinestesia.Bench.Stt do
  @shortdoc "Streaming STT shoot-out on real sung audio: WER × latency × cost"
  @moduledoc """
  Which speech-to-text should the show run? This streams the same sung clips
  through every engine at REAL-TIME pace, through the very client modules the
  pipeline uses (`ElevenSTT`, `Deepgram`, `GeminiSTT`, `LocalWhisperSTT`), and
  scores what comes back:

    * **WER** against the song's real lyrics, per language (pt/en/it/de), in
      AUTO-language mode unless a `-hint` variant pins it;
    * **latency** — how far behind the voice each final (and partial)
      arrived, placed against a timed anchor transcription (see
      `Sinestesia.SttBench`); finals gate the stage's reveals;
    * **follow rate** — the share of lyric lines `PerformanceFollower` would
      have confirmed from the finals, and how long after each line ended;
    * **cost** per hour of streamed audio, at list price.

  Usage:

      mix sinestesia.bench.stt --prepare            # build the corpus (once)
      mix sinestesia.bench.stt                      # every cloud engine with a key
      mix sinestesia.bench.stt --variants eleven,gemini --clips it-pausini
      mix sinestesia.bench.stt --whisper tiny,small,large-v3-turbo \\
                               --whisper-backend faster-whisper --whisper-threads 12
      mix sinestesia.bench.stt --whisper small --whisper-tag 4lang \\
        --whisper-env "WHISPER_LANGUAGES=pt,en,it,de;INTERIM_INTERVAL_MS=1000"  # sidecar knobs (';'-separated)
      mix sinestesia.bench.stt --report bench-stt-A,bench-stt-B   # merge runs
      mix sinestesia.bench.stt --report bench-stt-A --rescore     # after fixing a ref

  The corpus is `tests/stt/corpus.json`: clips of real singing (the duo's own
  takes and isolated studio vocals), each with a source, a window and where
  its lyrics come from. `--prepare` downloads/isolates the vocals (yt-dlp +
  Demucs, cached like `mix sinestesia.video`), cuts the 16 kHz clips into
  `tests/stt/corpus/` (gitignored), fetches lyrics from lrclib.net, and makes
  the timed anchor with a local Whisper sidecar (`--anchor-model`, default
  large-v3) — then derives each clip's reference text, which is written to
  `<id>.ref.txt` and never overwritten without `--fresh`, so a human can
  correct it.

  Cloud variants listen to one real-time stream `--parallel` at a time
  (default 3): each costs ~40 KB/s of upload, and a saturated uplink queues
  the audio and inflates exactly the latency being measured — run this on an
  otherwise idle network (no downloads) for numbers worth comparing. Each
  `--whisper` model gets its own sidecar on free ports and its own pass, so
  local models never share the CPU/GPU with each other. Results land in
  `bench-stt-<timestamp>/` (results.json + report.md); raw events are kept,
  so `--rescore` re-scores them after a reference is corrected.
  Costs: a full corpus pass is ~8 min of audio per engine — cents.
  """
  use Mix.Task
  require Logger

  alias Sinestesia.SttBench

  @manifest "../tests/stt/corpus.json"
  @corpus "../tests/stt/corpus"
  @whisper_dir "../local-whisper"

  # Silence streamed after each clip so every engine's VAD/turn detector can
  # close the last phrase, then a grace period for the reply to land.
  @tail_ms 4_000
  @grace_ms 4_000

  # List prices in USD per hour of streamed audio, checked 2026-10-20 on each
  # vendor's pricing page. Streaming bills by the minute the socket hears,
  # silence between songs included.
  @prices %{
    elevenlabs: {0.39, "Scribe v2 Realtime list price"},
    "nova-3": {0.348, "Nova-3 Multilingual $0.0058/min (promo rate)"},
    "flux-general-multi": {0.468, "Flux Multilingual $0.0078/min"},
    "gemini-3.5-transcribe-live": {0.54, "$0.005/min audio in + ~$0.004/min text out"},
    "gemini-3.8-live": {0.30, "$0.005/min audio in (+$0.018/min if it ever speaks)"},
    local: {0.0, "local hardware"}
  }

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          prepare: :boolean,
          fresh: :boolean,
          variants: :string,
          clips: :string,
          whisper: :string,
          whisper_backend: :string,
          whisper_threads: :integer,
          whisper_env: :string,
          whisper_tag: :string,
          medleys_only: :boolean,
          anchor_model: :string,
          chunk_ms: :integer,
          parallel: :integer,
          report: :string,
          rescore: :boolean,
          verbose: :boolean
        ]
      )

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:ssl, :req])
    unless opts[:verbose], do: Logger.configure(level: :warning)

    cond do
      opts[:report] ->
        dirs = String.split(opts[:report], ",", trim: true)
        results = Enum.flat_map(dirs, &(Path.join(&1, "results.json") |> File.read!() |> Jason.decode!()))
        results = if opts[:rescore], do: Enum.map(results, &rescore/1), else: results
        Mix.shell().info(report(results))

      opts[:prepare] ->
        prepare(select_clips(opts), opts)

      true ->
        bench(select_clips(opts), opts)
    end
  end

  # ── corpus ─────────────────────────────────────────────────────────────

  defp select_clips(opts) do
    all = @manifest |> File.read!() |> Jason.decode!() |> Map.fetch!("clips")

    case opts[:clips] do
      nil -> all
      ids -> Enum.filter(all, &(&1["id"] in String.split(ids, ",", trim: true)))
    end
  end

  # A medley strings prepared clips into ONE session, the way a set moves
  # from song to song — only when the whole corpus is being run.
  defp select_medleys(opts) do
    if opts[:clips] && !opts[:medleys_only] do
      []
    else
      manifest = @manifest |> File.read!() |> Jason.decode!()
      clips = Map.new(manifest["clips"], &{&1["id"], &1})

      for m <- Map.get(manifest, "medleys", []) do
        %{m | "parts" => Enum.map(m["parts"], &Map.fetch!(clips, &1))}
      end
    end
  end

  defp clip_path(clip, ext), do: Path.join(@corpus, "#{clip["id"]}.#{ext}")

  defp prepare(clips, opts) do
    File.mkdir_p!(@corpus)
    fresh? = opts[:fresh] || false
    anchor_model = opts[:anchor_model] || "large-v3"
    sidecar = :not_started

    sidecar =
      Enum.reduce(clips, sidecar, fn clip, sidecar ->
        Mix.shell().info("── #{clip["id"]} (#{clip["lang"]}) #{clip["title"]}")
        :ok = cut_clip(clip, fresh?)
        lyrics = fetch_lyrics(clip, fresh?)

        {sidecar, words} =
          # Re-anchored when the anchor model changes; the reference text
          # survives that (it may have been corrected by hand).
          case {fresh?, read_json(clip_path(clip, "anchor.json"))} do
            {false, %{"words" => words, "anchor_model" => ^anchor_model}} ->
              {sidecar, words}

            _ ->
              sidecar = ensure_anchor_sidecar(sidecar, anchor_model)
              {sidecar, transcribe_anchor(clip, sidecar)}
          end

        build_reference(clip, lyrics, words, fresh?, anchor_model)
        sidecar
      end)

    stop_sidecar(sidecar)
    Mix.shell().info("\ncorpus ready in #{Path.expand(@corpus)} — review the *.ref.txt files")
  end

  defp cut_clip(clip, fresh?) do
    out = clip_path(clip, "wav")

    if File.exists?(out) and not fresh? do
      :ok
    else
      vocals = source_vocals(clip)

      args =
        ["-y", "-v", "error", "-ss", to_string(clip["start"] || 0)] ++
          if(clip["duration"], do: ["-t", to_string(clip["duration"])], else: []) ++
          ["-i", vocals, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", out]

      {_, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
      Mix.shell().info("   clip → #{out}")
      :ok
    end
  end

  # The vocal stem a stage mic approximates: Demucs over the source (URL or
  # local file), cached per source like `mix sinestesia.video` does.
  defp source_vocals(%{"source" => src} = clip) do
    if clip["vocals"] == false do
      local_or_download(src)
    else
      dir = Sinestesia.MediaSource.cache_dir(cache_key(src))
      {:ok, vocals} = Sinestesia.MediaSource.separate_vocals(local_or_download(src), dir)
      vocals
    end
  end

  defp cache_key(src) do
    if Sinestesia.MediaSource.url?(src), do: src, else: "file://" <> Path.expand(Path.join("..", src))
  end

  defp local_or_download(src) do
    if Sinestesia.MediaSource.url?(src) do
      {:ok, %{audio: audio}} = Sinestesia.MediaSource.download(src, Sinestesia.MediaSource.cache_dir(src))
      audio
    else
      # Demucs reads audio, not containers — extract the track first.
      dir = Sinestesia.MediaSource.cache_dir(cache_key(src))
      wav = Path.join(dir, "source.wav")

      unless File.exists?(wav) do
        {_, 0} =
          System.cmd("ffmpeg", ["-y", "-v", "error", "-i", Path.join("..", src), "-vn", wav],
            stderr_to_stdout: true
          )
      end

      wav
    end
  end

  # lrclib.net: open, keyless, and it carries lyrics as SUNG (repeats written
  # out), which is what a reference needs. A `lyrics_file` in the manifest
  # wins — for the duo's own songs, which no site has.
  defp fetch_lyrics(clip, fresh?) do
    cached = clip_path(clip, "lyrics.txt")

    cond do
      clip["lyrics_file"] ->
        File.read!(Path.join("..", clip["lyrics_file"]))

      File.exists?(cached) and not fresh? ->
        File.read!(cached)

      true ->
        %{"artist" => artist, "track" => track} = clip["lyrics"]

        {:ok, %{status: 200, body: hits}} =
          Req.get("https://lrclib.net/api/search",
            params: [artist_name: artist, track_name: track],
            headers: [{"user-agent", "sinestesia-bench (github.com/danicuki/sinestesia)"}],
            receive_timeout: 30_000
          )

        case Enum.find(hits, &is_binary(&1["plainLyrics"])) do
          nil ->
            Mix.raise("no lyrics on lrclib for #{artist} — #{track}; add a lyrics_file")

          hit ->
            File.write!(cached, hit["plainLyrics"])
            hit["plainLyrics"]
        end
    end
  end

  defp transcribe_anchor(clip, sidecar) do
    System.put_env("LOCAL_WHISPER_BATCH_PORT", to_string(sidecar.batch_port))

    {:ok, words} =
      Sinestesia.BatchStt.transcribe(Path.expand(clip_path(clip, "wav")),
        provider: :local_whisper,
        lang: clip["lang"]
      )

    words = Enum.map(words, &%{"text" => &1.text, "start" => &1.start, "end" => &1.end})
    File.write!(clip_path(clip, "anchor.json"), Jason.encode!(%{"words" => words}, pretty: true))
    words
  end

  # The reference is the stretch of the real lyrics the anchor lines up with
  # — the lyrics give the right words, the anchor only says WHICH words are
  # in the clip and when each line ends.
  defp build_reference(clip, lyrics, words, fresh?, anchor_model) do
    ref_file = clip_path(clip, "ref.txt")
    anchor = anchor_tokens(words)

    lines =
      if File.exists?(ref_file) and not fresh? do
        ref_file |> File.read!() |> String.split("\n", trim: true)
      else
        lines = slice_lyrics(lyrics, Enum.map(anchor, & &1.token))
        File.write!(ref_file, Enum.join(lines, "\n") <> "\n")
        lines
      end

    ends = line_ends(lines, anchor)

    meta = %{
      "anchor_model" => anchor_model,
      "words" => words,
      "anchor_text" => Enum.map_join(words, " ", & &1["text"]),
      "line_ends" => ends
    }

    File.write!(clip_path(clip, "anchor.json"), Jason.encode!(meta, pretty: true))

    Mix.shell().info(
      "   ref: #{length(lines)} lines, #{lines |> Enum.join(" ") |> SttBench.tokens() |> length()} words · anchor: #{length(anchor)} words"
    )
  end

  defp anchor_tokens(words) do
    Enum.flat_map(words, fn w ->
      w["text"] |> SttBench.tokens() |> Enum.map(&%{token: &1, end: w["end"]})
    end)
  end

  defp slice_lyrics(lyrics, anchor) do
    words =
      lyrics
      |> String.split("\n", trim: true)
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, li} ->
        line
        |> String.split(~r/\s+/, trim: true)
        |> Enum.map(&{&1, li, SttBench.tokens(&1)})
      end)
      |> Enum.reject(fn {_, _, toks} -> toks == [] end)

    flat =
      words
      |> Enum.with_index()
      |> Enum.flat_map(fn {{_, _, toks}, wi} -> Enum.map(toks, &{&1, wi}) end)

    case SttBench.locate(anchor, Enum.map(flat, &elem(&1, 0))) do
      nil ->
        Mix.raise("the anchor transcript doesn't align with these lyrics — wrong song or window?")

      {from, to} ->
        {_, w_from} = Enum.at(flat, from)
        {_, w_to} = Enum.at(flat, to)

        words
        |> Enum.slice(w_from..w_to)
        |> Enum.chunk_by(fn {_, li, _} -> li end)
        |> Enum.map(fn ws -> Enum.map_join(ws, " ", &elem(&1, 0)) end)
    end
  end

  # Seconds at which each reference line's last word was sung, per anchor.
  defp line_ends(lines, anchor) do
    ref =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {l, li} -> l |> SttBench.tokens() |> Enum.map(&{&1, li}) end)

    pairs = SttBench.local_align(Enum.map(ref, &elem(&1, 0)), Enum.map(anchor, & &1.token), prefer: :first)
    ref_t = List.to_tuple(ref)
    anchor_t = List.to_tuple(anchor)

    by_line =
      Enum.reduce(pairs, %{}, fn {i, j}, acc ->
        {_, li} = elem(ref_t, i)
        Map.update(acc, li, elem(anchor_t, j).end, &max(&1, elem(anchor_t, j).end))
      end)

    for li <- 0..(length(lines) - 1)//1, do: by_line[li]
  end

  # ── bench ──────────────────────────────────────────────────────────────

  defp bench(clips, opts) do
    Enum.each(clips, fn c ->
      File.exists?(clip_path(c, "ref.txt")) ||
        Mix.raise("clip #{c["id"]} is not prepared — run with --prepare first")
    end)

    Process.flag(:trap_exit, true)
    chunk_ms = opts[:chunk_ms] || 250
    cloud = cloud_variants(opts)
    whisper = whisper_variants(opts)

    passes =
      Enum.chunk_every(cloud, max(opts[:parallel] || 3, 1)) ++ Enum.map(whisper, &[&1])

    passes == [] && Mix.raise("nothing to run — no API keys found and no --whisper models given")

    dir = "bench-stt-#{System.os_time(:second)}"
    File.mkdir_p!(dir)

    Mix.shell().info(
      "── stt bench: #{length(clips)} clips × #{passes |> List.flatten() |> length()} variants, #{chunk_ms}ms chunks → #{dir}/\n"
    )

    results =
      Enum.flat_map(passes, fn variants ->
        {variants, sidecar} = boot_sidecar(variants, opts, dir)

        try do
          Enum.flat_map(if(opts[:medleys_only], do: [], else: clips), fn clip ->
            Mix.shell().info("   #{clip["id"]}: #{Enum.map_join(variants, ", ", & &1.id)}")
            run_clip(clip, variants, chunk_ms)
          end) ++
            Enum.flat_map(select_medleys(opts), fn medley ->
              # A pinned language can't follow a set across languages.
              auto = Enum.reject(variants, &String.ends_with?(&1.id, "-hint"))
              Mix.shell().info("   #{medley["id"]}: #{Enum.map_join(auto, ", ", & &1.id)}")
              run_medley(medley, auto, chunk_ms)
            end)
        after
          stop_sidecar(sidecar)
        end
      end)

    File.write!(Path.join(dir, "results.json"), Jason.encode!(results, pretty: true))
    md = report(Jason.decode!(Jason.encode!(results)))
    File.write!(Path.join(dir, "report.md"), md)
    Mix.shell().info("\n" <> md)
  end

  defp key?(name) do
    cfg = Application.get_env(:sinestesia, :config, [])
    v = Keyword.get(cfg, name)
    is_binary(v) and v != ""
  end

  # Every variant pins ALL of its provider's knobs, so one never inherits the
  # previous one's language or model through the shared environment.
  defp catalog do
    eleven = fn lang, commit ->
      fn clip ->
        %{"ELEVEN_MODEL" => "scribe_v2_realtime", "ELEVEN_LANG" => lang.(clip), "ELEVEN_COMMIT" => commit}
      end
    end

    dg = fn model, lang ->
      fn clip -> %{"DEEPGRAM_MODEL" => model, "DEEPGRAM_LANGUAGE" => lang.(clip)} end
    end

    gem = fn model, lang ->
      fn clip -> %{"GEMINI_STT_MODEL" => model, "GEMINI_STT_LANG" => lang.(clip), "GEMINI_STT_SILENCE_MS" => ""} end
    end

    auto = fn _ -> "" end
    multi = fn _ -> "multi" end
    iso = fn clip -> clip["lang"] end
    dg_code = fn clip -> if clip["lang"] == "pt", do: "pt-BR", else: clip["lang"] end
    bcp47 = fn clip -> %{"pt" => "pt-BR", "en" => "en-US", "it" => "it-IT", "de" => "de-DE"}[clip["lang"]] end

    [
      {"eleven", :elevenlabs, :elevenlabs_api_key, :elevenlabs, eleven.(auto, "vad")},
      {"eleven-hint", :elevenlabs, :elevenlabs_api_key, :elevenlabs, eleven.(iso, "vad")},
      {"eleven-turn", :elevenlabs, :elevenlabs_api_key, :elevenlabs, eleven.(auto, "turn_prediction")},
      {"deepgram", :deepgram, :deepgram_api_key, :"nova-3", dg.("nova-3", multi)},
      {"deepgram-hint", :deepgram, :deepgram_api_key, :"nova-3", dg.("nova-3", dg_code)},
      {"flux", :deepgram, :deepgram_api_key, :"flux-general-multi", dg.("flux-general-multi", multi)},
      {"gemini", :gemini, :google_api_key, :"gemini-3.5-transcribe-live",
       gem.("gemini-3.5-transcribe-live", auto)},
      {"gemini-hint", :gemini, :google_api_key, :"gemini-3.5-transcribe-live",
       gem.("gemini-3.5-transcribe-live", bcp47)},
      {"gemini-live", :gemini, :google_api_key, :"gemini-3.8-live", gem.("gemini-3.8-live", auto)}
    ]
    |> Enum.map(fn {id, provider, key, price, env} ->
      %{id: id, provider: provider, key: key, price: price, env: env}
    end)
  end

  defp cloud_variants(opts) do
    wanted =
      case opts[:variants] do
        nil -> nil
        list -> String.split(list, ",", trim: true)
      end

    cond do
      wanted == [] ->
        []

      wanted ->
        unknown = wanted -- Enum.map(catalog(), & &1.id)
        unknown != [] && Mix.raise("unknown variant(s): #{Enum.join(unknown, ", ")}")
        Enum.filter(catalog(), &(&1.id in wanted))

      opts[:whisper] ->
        []

      true ->
        {have, missing} = Enum.split_with(catalog(), &key?(&1.key))

        missing
        |> Enum.map(& &1.key)
        |> Enum.uniq()
        |> Enum.each(&Mix.shell().info("(#{&1 |> to_string() |> String.upcase()} unset — skipping its variants)"))

        have
    end
    |> Enum.filter(fn v ->
      key?(v.key) || (Mix.shell().info("(skipping #{v.id}: #{v.key |> to_string() |> String.upcase()} unset)") && false)
    end)
  end

  defp whisper_variants(opts) do
    case opts[:whisper] do
      nil ->
        []

      list ->
        for model <- String.split(list, ",", trim: true) do
          %{
            id:
              "whisper-" <> whisper_name(model) <>
                if(opts[:whisper_threads], do: "@#{opts[:whisper_threads]}t", else: "") <>
                if(opts[:whisper_tag], do: "+#{opts[:whisper_tag]}", else: ""),
            provider: :local_whisper,
            price: :local,
            model: model,
            backend: opts[:whisper_backend],
            threads: opts[:whisper_threads],
            sidecar_env: parse_env(opts[:whisper_env]),
            env: fn _ -> %{} end
          }
        end
    end
  end

  # "small", "~/models/faster-whisper-large-v3-turbo" and
  # "mlx-community/whisper-small-mlx" all name the model by its size.
  defp whisper_name(model) do
    model
    |> String.split("/")
    |> List.last()
    |> String.replace_prefix("faster-whisper-", "")
    |> String.replace_prefix("whisper-", "")
  end

  # ── one clip, many engines, one real-time stream ───────────────────────

  @modules %{
    elevenlabs: Sinestesia.ElevenSTT,
    deepgram: Sinestesia.Deepgram,
    gemini: Sinestesia.GeminiSTT,
    local_whisper: Sinestesia.LocalWhisperSTT
  }

  defp run_clip(clip, variants, chunk_ms) do
    pcm = clip |> clip_path("wav") |> File.read!() |> wav_data()
    {ref_lines, meta, anchor} = load_reference(clip)
    events = stream(variants, clip, pcm, chunk_ms, [])

    for v <- variants do
      mine = for {id, kind, text, t} <- events, id == v.id, do: {kind, text, t}
      score(clip, v, mine, ref_lines, meta["line_ends"], anchor)
    end
  end

  # The parts back to back with `gap` seconds of silence, in ONE session per
  # engine. Mid-gap, every engine gets what the pipeline's song change gives
  # it (`reset_stt/2`: local Whisper drops its locked language; the cloud
  # engines get nothing) — so this measures auto-language across a set as the
  # show would actually run it. Each part is then scored on its own window.
  defp run_medley(medley, variants, chunk_ms) do
    gap_s = medley["gap"] || 3
    gap = :binary.copy(<<0>>, round(gap_s * 16_000) * 2)
    pcms = Enum.map(medley["parts"], &(&1 |> clip_path("wav") |> File.read!() |> wav_data()))

    offsets =
      pcms
      |> Enum.scan(0, fn pcm, acc -> acc + byte_size(pcm) + byte_size(gap) end)
      |> then(&[0 | Enum.drop(&1, -1)])
      |> Enum.map(&(&1 / 32))

    # Offsets are ms (32 bytes of 16 kHz s16 per ms); the reset lands in the
    # middle of each gap, the chunk index the streamer counts in.
    resets = for off <- tl(offsets), do: round((off - gap_s * 500) / chunk_ms)

    events = stream(variants, hd(medley["parts"]), Enum.join(pcms, gap), chunk_ms, resets)
    parts = Enum.zip(medley["parts"], offsets)
    refs = Map.new(parts, fn {part, _} -> {part["id"], load_reference(part)} end)

    # An event belongs to the song it TRANSCRIBES, not to whichever song was
    # playing when it arrived: a slow engine delivers the end of one song
    # well into the next. Among the songs already started, the one whose
    # lyrics it aligns with best wins; text that aligns with none (wrong
    # language, garbage) falls back to the song playing at the time.
    owner = fn text, t ->
      started = Enum.filter(parts, fn {_, off} -> off <= t end)
      toks = SttBench.tokens(text)

      {best, hits} =
        started
        |> Enum.map(fn {part, _} = p ->
          {ref_lines, _, _} = refs[part["id"]]
          {p, length(SttBench.local_align(toks, ref_lines |> Enum.join(" ") |> SttBench.tokens()))}
        end)
        |> Enum.max_by(fn {_, hits} -> hits end, fn -> {List.last(started), 0} end)

      if hits >= min(2, length(toks)) and hits > 0, do: best, else: List.last(started)
    end

    owned =
      for {id, kind, text, t} <- events, (p = owner.(text, t)) != nil do
        {part, off} = p
        {part["id"], id, kind, text, t - off}
      end

    for {part, _} <- parts, v <- variants do
      {ref_lines, meta, anchor} = refs[part["id"]]
      mine = for {pid, id, kind, text, t} <- owned, pid == part["id"], id == v.id, do: {kind, text, t}

      part
      |> Map.put("id", "#{medley["id"]}:#{part["id"]}")
      |> score(v, mine, ref_lines, meta["line_ends"], anchor)
      |> Map.put(:medley, medley["id"])
      |> Map.put(:standalone, part["id"])
    end
  end

  defp load_reference(clip) do
    ref_lines = clip |> clip_path("ref.txt") |> File.read!() |> String.split("\n", trim: true)
    meta = clip |> clip_path("anchor.json") |> File.read!() |> Jason.decode!()
    {ref_lines, meta, anchor_tokens(meta["words"])}
  end

  # Streams `pcm` to every variant at real-time pace, then tail silence.
  # Returns `[{variant_id, kind, text, ms_since_stream_start}]`. `resets` are
  # chunk indices at which engines that keep song state are reset.
  defp stream(variants, env_clip, pcm, chunk_ms, resets) do
    bench = self()

    clients =
      Enum.flat_map(variants, fn v ->
        Enum.each(v.env.(env_clip), fn {k, val} -> System.put_env(k, val) end)
        relay = spawn_link(fn -> relay(bench, v.id) end)
        mod = @modules[v.provider]

        case mod.start_link(relay) do
          {:ok, pid} ->
            [{v, mod, pid, relay}]

          {:error, reason} ->
            send(bench, {:stt_bench, v.id, :error, inspect(reason), System.system_time(:millisecond)})
            [{v, nil, nil, relay}]
        end
      end)

    live = for {_, mod, pid, _} <- clients, pid != nil, do: {mod, pid}
    bytes = div(16_000 * 2 * chunk_ms, 1000)
    silence = :binary.copy(<<0>>, bytes)
    chunks = chunk(pcm, bytes) ++ List.duplicate(silence, div(@tail_ms, chunk_ms))

    t0 = System.monotonic_time(:millisecond)
    wall0 = System.system_time(:millisecond)

    chunks
    |> Enum.with_index(1)
    |> Enum.each(fn {c, i} ->
      wait = t0 + i * chunk_ms - System.monotonic_time(:millisecond)
      if wait > 0, do: Process.sleep(wait)
      Enum.each(live, fn {mod, pid} -> mod.send_audio(pid, c) end)

      if i in resets do
        for {Sinestesia.LocalWhisperSTT = mod, pid} <- live, do: mod.reset(pid)
      end
    end)

    Process.sleep(@grace_ms)

    Enum.each(clients, fn {_, _, pid, relay} ->
      if pid, do: safe_stop(pid)
      send(relay, :stop)
    end)

    for {id, kind, text, ts} <- drain([]), do: {id, kind, text, ts - wall0}
  end

  defp relay(bench, id) do
    receive do
      {:transcript, _p, text, final?, ts} ->
        send(bench, {:stt_bench, id, if(final?, do: :final, else: :partial), text, ts})
        relay(bench, id)

      {:stt_error, _p, reason} ->
        send(bench, {:stt_bench, id, :error, inspect(reason), System.system_time(:millisecond)})
        relay(bench, id)

      :stop ->
        :ok

      _ ->
        relay(bench, id)
    end
  end

  defp drain(acc) do
    receive do
      {:stt_bench, id, kind, text, ts} -> drain([{id, kind, text, ts} | acc])
      {:EXIT, _, _} -> drain(acc)
    after
      0 -> Enum.sort_by(acc, &elem(&1, 3))
    end
  end

  defp safe_stop(pid) do
    GenServer.stop(pid, :normal, 2_000)
  catch
    :exit, _ -> :ok
  end

  defp score(clip, v, events, ref_lines, line_ends, anchor) do
    finals = for {:final, text, t} <- events, do: %{t: t, text: text}
    partials = for {:partial, text, t} <- events, do: %{t: t, text: text}
    errors = for {:error, text, _} <- events, do: text
    hyp = Enum.map_join(finals, " ", & &1.text)
    ref = ref_lines |> Enum.join(" ") |> SttBench.tokens()
    w = SttBench.wer(ref, SttBench.tokens(hyp))
    follow = SttBench.follow(finals, ref_lines, line_ends)

    %{
      variant: v.id,
      provider: v.provider,
      price: v.price,
      clip: clip["id"],
      lang: clip["lang"],
      ref_words: w.n,
      errors_words: w.errors,
      wer: w.wer,
      final_lags: SttBench.lags(finals, anchor),
      partial_lags: SttBench.lags(partials, anchor),
      lines: follow.lines,
      lines_confirmed: follow.confirmed,
      confirm_delays: follow.delays,
      n_finals: length(finals),
      n_partials: length(partials),
      errors: Enum.uniq(errors),
      hyp: hyp,
      events: Enum.map(events, &Tuple.to_list/1)
    }
  end

  # Re-score a stored result against the clip's CURRENT reference and anchor.
  defp rescore(r) do
    clip = %{"id" => r["standalone"] || r["clip"], "lang" => r["lang"]}
    ref_lines = clip |> clip_path("ref.txt") |> File.read!() |> String.split("\n", trim: true)
    meta = clip |> clip_path("anchor.json") |> File.read!() |> Jason.decode!()
    events = Enum.map(r["events"], fn [kind, text, t] -> {String.to_existing_atom(kind), text, t} end)
    v = %{id: r["variant"], provider: r["provider"], price: r["price"]}

    clip
    |> score(v, events, ref_lines, meta["line_ends"], anchor_tokens(meta["words"]))
    |> Jason.encode!()
    |> Jason.decode!()
    |> Map.merge(Map.take(r, ["clip", "medley", "standalone"]))
  end

  defp wav_data(<<"RIFF", _::32, "WAVE", rest::binary>>), do: find_data(rest)

  defp find_data(<<"data", size::little-32, data::binary>>),
    do: binary_part(data, 0, min(size, byte_size(data)))

  defp find_data(<<_id::binary-4, size::little-32, rest::binary>>) do
    skip = size + rem(size, 2)
    find_data(binary_part(rest, skip, byte_size(rest) - skip))
  end

  defp chunk(pcm, bytes) when byte_size(pcm) <= bytes, do: [pcm]

  defp chunk(pcm, bytes) do
    <<c::binary-size(bytes), rest::binary>> = pcm
    [c | chunk(rest, bytes)]
  end

  # ── local whisper sidecars ─────────────────────────────────────────────

  defp boot_sidecar(variants, _opts, dir) do
    case Enum.find(variants, &(&1.provider == :local_whisper)) do
      nil ->
        {variants, :not_started}

      w ->
        Mix.shell().info("   starting whisper sidecar: #{w.model} (#{w.backend || "sidecar default backend"})")
        sc =
          start_sidecar(w.model, w.backend, Path.join(dir, "sidecar-#{w.id}.log"),
            threads: w.threads,
            env: w.sidecar_env
          )
        env = fn _ -> %{"LOCAL_WHISPER_PORT" => to_string(sc.ws_port), "LOCAL_WHISPER_HOST" => "127.0.0.1"} end
        {Enum.map(variants, &if(&1 == w, do: %{w | env: env}, else: &1)), sc}
    end
  end

  # Anchor transcription runs on the sidecar's batch endpoint, which is
  # faster-whisper regardless of backend — so the warm-up is forced onto it
  # too (the torch backend segfaults on some ROCm boxes before serving).
  defp ensure_anchor_sidecar(:not_started, model) do
    Mix.shell().info("   starting anchor sidecar (#{model}) — first run downloads the model")
    start_sidecar(model, "faster-whisper", Path.join(@corpus, "anchor-sidecar.log"), threads: 16)
  end

  defp ensure_anchor_sidecar(sc, _model), do: sc

  defp start_sidecar(model, backend, log, opts) do
    python = Path.expand(Path.join(@whisper_dir, ".venv/bin/python"))
    File.exists?(python) || Mix.raise("no local-whisper venv at #{python} — see local-whisper/README.md")
    ws_port = free_port()
    batch_port = free_port()

    env =
      [
        {"WHISPER_MODEL", model},
        {"BIND_PORT", ws_port},
        {"LOCAL_WHISPER_BATCH_PORT", batch_port}
      ] ++
        if(backend, do: [{"WHISPER_BACKEND", backend}], else: []) ++
        # CTranslate2 runs on 4 CPU threads unless OMP_NUM_THREADS says otherwise.
        if(opts[:threads], do: [{"OMP_NUM_THREADS", opts[:threads]}], else: []) ++
        Keyword.get(opts, :env, [])

    parent = self()

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, python}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["server.py"],
            cd: Path.expand(@whisper_dir),
            env: Enum.map(env, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(parent, {:sidecar, self(), os_pid})
        sidecar_loop(port, os_pid, File.open!(log, [:append]))
      end)

    os_pid =
      receive do
        {:sidecar, ^owner, p} -> p
      end

    deadline = System.monotonic_time(:second) + 3_600
    wait_listening(ws_port, owner, log, deadline)
    %{owner: owner, os_pid: os_pid, ws_port: ws_port, batch_port: batch_port}
  end

  defp sidecar_loop(port, os_pid, log) do
    receive do
      {^port, {:data, d}} ->
        IO.binwrite(log, d)
        sidecar_loop(port, os_pid, log)

      {^port, {:exit_status, s}} ->
        IO.binwrite(log, "\n[sidecar exited with status #{s}]\n")

      :stop ->
        System.cmd("kill", [to_string(os_pid)])
    end
  end

  defp wait_listening(port, owner, log, deadline) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 500) do
      {:ok, s} ->
        :gen_tcp.close(s)

      {:error, _} ->
        cond do
          not Process.alive?(owner) ->
            Mix.raise("whisper sidecar died while loading — see #{log}:\n" <> tail(log))

          System.monotonic_time(:second) > deadline ->
            Mix.raise("whisper sidecar never came up — see #{log}")

          true ->
            Process.sleep(1_000)
            wait_listening(port, owner, log, deadline)
        end
    end
  end

  # Synchronous: the task may exit right after this, and the BEAM going down
  # does not take the Python process with it (it never reads its stdin).
  defp stop_sidecar(%{owner: owner}) do
    ref = Process.monitor(owner)
    send(owner, :stop)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      10_000 -> :ok
    end
  end

  defp stop_sidecar(_), do: :ok

  defp tail(log), do: log |> File.read!() |> String.slice(-1500, 1500)

  # "K=V;K2=V2" → [{"K", "V"}, ...] for the sidecar's environment. Pairs are
  # separated by ";" because values have commas (WHISPER_LANGUAGES=pt,en,it,de).
  defp parse_env(nil), do: []

  defp parse_env(spec) do
    for kv <- String.split(spec, ";", trim: true) do
      case String.split(kv, "=", parts: 2) do
        [k, v] -> {String.trim(k), String.trim(v)}
        _ -> Mix.raise("--whisper-env expects KEY=VALUE pairs separated by ';', got #{inspect(kv)}")
      end
    end
  end

  defp free_port do
    {:ok, s} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    port
  end

  defp read_json(path) do
    with {:ok, raw} <- File.read(path), {:ok, data} <- Jason.decode(raw), do: data, else: (_ -> nil)
  end

  # ── report ─────────────────────────────────────────────────────────────

  defp report(all) do
    {medleys, results} = Enum.split_with(all, & &1["medley"])
    by_variant = Enum.group_by(results, & &1["variant"])
    langs = results |> Enum.map(& &1["lang"]) |> Enum.uniq() |> Enum.sort()

    rows =
      by_variant
      |> Enum.map(fn {variant, rs} -> summarize(variant, rs, langs) end)
      |> Enum.sort_by(& &1.wer)

    header =
      "| variant | WER | " <>
        Enum.map_join(langs, " | ", &"WER #{&1}") <>
        " | lines followed | final lag p50 / p90 | partial lag p50 | reveal delay p50 | $/h | errors |"

    sep = "|" <> String.duplicate("---|", 8 + length(langs))

    body =
      Enum.map_join(rows, "\n", fn r ->
        "| #{r.variant} | #{pct(r.wer)} | " <>
          Enum.map_join(langs, " | ", &pct(r.by_lang[&1])) <>
          " | #{pct(r.followed)} | #{ms(r.final_p50)} / #{ms(r.final_p90)} | #{ms(r.partial_p50)} | #{ms(r.reveal_p50)} | #{price(r.price)} | #{r.errors} |"
      end)

    notes =
      results
      |> Enum.filter(&(&1["errors"] != []))
      |> Enum.map_join("\n", &"- #{&1["variant"]} on #{&1["clip"]}: #{Enum.join(&1["errors"], "; ") |> String.slice(0, 240)}")

    """
    ## STT bench — #{length(Enum.uniq_by(results, & &1["clip"]))} clips, #{Enum.sum(Enum.map(Enum.uniq_by(results, & &1["clip"]), & &1["ref_words"]))} reference words

    WER: word error rate vs the real lyrics (follower normalization; lower is better).
    Lines followed: share of lyric lines PerformanceFollower confirmed from the finals.
    Lags: ms between the last sung word an event contains and its arrival (includes the
    250ms capture chunk, like the stage). Reveal delay: line end → follower confirmation.

    #{header}
    #{sep}
    #{body}
    #{medley_table(medleys, results)}
    #{if notes == "", do: "", else: "\nErrors:\n" <> notes}
    """
  end

  # Same engine, same audio: WER inside a multi-language session vs the
  # clip on its own. A jump means the engine kept the previous song's language.
  defp medley_table([], _), do: ""

  defp medley_table(medleys, singles) do
    parts = medleys |> Enum.map(& &1["standalone"]) |> Enum.uniq()
    alone = Map.new(singles, &{{&1["variant"], &1["clip"]}, &1["wer"]})

    rows =
      medleys
      |> Enum.group_by(& &1["variant"])
      |> Enum.sort_by(fn {v, _} -> v end)
      |> Enum.map_join("\n", fn {variant, rs} ->
        cells =
          Enum.map_join(parts, " | ", fn part ->
            r = Enum.find(rs, &(&1["standalone"] == part))
            "#{pct(r && r["wer"])} (alone #{pct(alone[{variant, part}])})"
          end)

        "| #{variant} | #{cells} |"
      end)

    """

    ### Language switching — #{hd(medleys)["medley"]}: one session, songs back to back

    | variant | #{Enum.join(parts, " | ")} |
    |#{String.duplicate("---|", 1 + length(parts))}
    #{rows}
    """
  end

  defp summarize(variant, rs, langs) do
    wer = fn rs ->
      n = rs |> Enum.map(& &1["ref_words"]) |> Enum.sum()
      if n == 0, do: nil, else: (rs |> Enum.map(& &1["errors_words"]) |> Enum.sum()) / n
    end

    finals = Enum.flat_map(rs, & &1["final_lags"])
    lines = rs |> Enum.map(& &1["lines"]) |> Enum.sum()

    %{
      variant: variant,
      wer: wer.(rs),
      by_lang: Map.new(langs, fn l -> {l, wer.(Enum.filter(rs, &(&1["lang"] == l)))} end),
      followed: if(lines == 0, do: nil, else: (rs |> Enum.map(& &1["lines_confirmed"]) |> Enum.sum()) / lines),
      final_p50: SttBench.pct(finals, 50),
      final_p90: SttBench.pct(finals, 90),
      partial_p50: SttBench.pct(Enum.flat_map(rs, & &1["partial_lags"]), 50),
      reveal_p50: SttBench.pct(Enum.flat_map(rs, & &1["confirm_delays"]), 50),
      price: hd(rs)["price"],
      errors: rs |> Enum.map(&length(&1["errors"])) |> Enum.sum()
    }
  end

  defp pct(nil), do: "—"
  defp pct(x), do: "#{Float.round(x * 100, 1)}%"
  defp ms(nil), do: "—"
  defp ms(x), do: "#{round(x)}"

  defp price(key) do
    case @prices[if(is_binary(key), do: String.to_atom(key), else: key)] do
      {usd, _} -> "#{usd}"
      nil -> "?"
    end
  end
end
