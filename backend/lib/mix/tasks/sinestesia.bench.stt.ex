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
      mix sinestesia.bench.stt                      # EVERYTHING: every cloud engine with a key
                                                    # + local Whisper (small, large-v3-turbo)
      mix sinestesia.bench.stt --variants eleven,gemini --clips it-pausini
      mix sinestesia.bench.stt --whisper tiny,medium               # more local sizes
      mix sinestesia.bench.stt --whisper small --whisper-tag beam5 \\
        --whisper-env "WHISPER_BEAM_SIZE=5;INTERIM_INTERVAL_MS=1000"  # sidecar knobs (';'-separated)
      mix sinestesia.bench.stt --dry-run            # what a run would measure, and what it would keep
      mix sinestesia.bench.stt --report             # the table over everything measured so far
      mix sinestesia.bench.stt --rescore            # re-score it all after fixing a ref
      mix sinestesia.bench.stt --import bench-stt-1792587923   # an older per-run dir into the store

  Results accumulate in `bench-stt/` — one `results/<variant>.json` per
  engine and a `report.md` over all of them — so engines can be measured one
  at a time, on different days and machines. A variant that already has rows
  for the selected clips is asked about before anything is streamed: answer
  no and the stored rows stand (`--overwrite` / `--reuse` answer for every
  variant). The report at the end always covers the whole store and marks
  which rows are fresh.

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
  local Whisper model gets its own sidecar on free ports and its own pass, so
  local models never share the CPU/GPU with each other; the backend is
  whatever the sidecar's venv can run (mlx on Apple Silicon, CTranslate2
  elsewhere) and detection is restricted to the corpus languages, as
  `WHISPER_LANGUAGES` does on stage. Raw events are kept with every row, so
  `--rescore` re-scores them after a reference is corrected.
  Costs: a full corpus pass is ~8 min of audio per engine — cents.
  """
  use Mix.Task
  require Logger

  alias Sinestesia.SttBench

  @manifest "../tests/stt/corpus.json"
  @corpus "../tests/stt/corpus"
  @whisper_dir "../local-whisper"
  # Where results accumulate: results/<variant>.json, logs/, report.md.
  @store "bench-stt"

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
          report: :boolean,
          rescore: :boolean,
          import: :string,
          overwrite: :boolean,
          reuse: :boolean,
          dry_run: :boolean,
          verbose: :boolean
        ]
      )

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:ssl, :req])
    unless opts[:verbose], do: Logger.configure(level: :warning)

    cond do
      opts[:import] -> import_runs(opts[:import], opts)
      opts[:report] || opts[:rescore] -> finish([], opts)
      opts[:prepare] -> prepare(select_clips(opts), opts)
      true -> bench(select_clips(opts), opts)
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
    medleys = select_medleys(opts)
    clips = if opts[:medleys_only], do: [], else: clips

    # The rows this run would produce — so a variant that already has them
    # is asked about before anything is streamed.
    keys =
      MapSet.new(
        Enum.map(clips, &{&1["id"], nil}) ++
          for(m <- medleys, p <- m["parts"], do: {"#{m["id"]}:#{p["id"]}", m["id"]})
      )

    variants = cloud_variants(opts) ++ whisper_variants(opts)

    variants == [] &&
      Mix.raise("nothing to run — no API keys found and no local-whisper venv (or --whisper models)")

    {run, kept} = Enum.split_with(variants, &(decide(&1.id, keys, "Re-run", opts) == :run))
    kept != [] && Mix.shell().info("   stored rows stand for: #{Enum.map_join(kept, ", ", & &1.id)}")

    if opts[:dry_run] do
      Enum.each(run, fn v ->
        model = if v.provider == :local_whisper, do: " · #{v.model} on #{v.backend}", else: ""
        Mix.shell().info("   would run #{v.id}#{model}")
      end)

      exit({:shutdown, 0})
    end

    {cloud, whisper} = Enum.split_with(run, &(&1.provider != :local_whisper))
    passes = Enum.chunk_every(cloud, max(opts[:parallel] || 3, 1)) ++ Enum.map(whisper, &[&1])

    if passes != [] do
      Mix.shell().info(
        "── stt bench: #{length(clips)} clips × #{length(run)} variants, #{chunk_ms}ms chunks → #{@store}/"
      )

      # Cloud engines go --parallel at a time, each local model alone; every
      # pass plays the whole corpus before the next one starts.
      passes
      |> Enum.with_index(1)
      |> Enum.each(fn {vs, i} ->
        Mix.shell().info("   pass #{i}/#{length(passes)}: #{Enum.map_join(vs, ", ", & &1.id)}")
      end)
    end

    # Each pass is stored as soon as it is scored, so a crash in a later pass
    # (a sidecar that will not start) does not cost the cloud rows.
    passes
    |> Enum.with_index(1)
    |> Enum.each(fn {variants, i} ->
      Mix.shell().info("\n── pass #{i}/#{length(passes)}: #{Enum.map_join(variants, ", ", & &1.id)}")
      {variants, sidecar} = boot_sidecar(variants, opts)

      rows =
        try do
          Enum.flat_map(clips, fn clip ->
            Mix.shell().info("   #{clip["id"]}: #{Enum.map_join(variants, ", ", & &1.id)}")
            run_clip(clip, variants, chunk_ms)
          end) ++
            Enum.flat_map(medleys, fn medley ->
              # A pinned language can't follow a set across languages.
              auto = Enum.reject(variants, &String.ends_with?(&1.id, "-hint"))
              Mix.shell().info("   #{medley["id"]}: #{Enum.map_join(auto, ", ", & &1.id)}")
              run_medley(medley, auto, chunk_ms)
            end)
        after
          stop_sidecar(sidecar)
        end

      rows
      |> Jason.encode!()
      |> Jason.decode!()
      |> Enum.group_by(& &1["variant"])
      |> Enum.each(fn {id, rs} -> store_rows(id, rs) end)
    end)

    finish(Enum.map(run, & &1.id), opts)
  end

  # ── the store: one file per variant, the report over all of them ───────

  defp store_file(id), do: Path.join([@store, "results", id <> ".json"])
  defp cached_rows(id), do: read_json(store_file(id)) || []
  defp row_key(r), do: {r["clip"], r["medley"]}

  # New rows replace stored ones for the same clip; rows for clips not in
  # this run stay, so `--clips` refreshes part of a variant.
  defp store_rows(id, rows) do
    File.mkdir_p!(Path.dirname(store_file(id)))
    keys = MapSet.new(rows, &row_key/1)
    kept = Enum.reject(cached_rows(id), &(row_key(&1) in keys))
    File.write!(store_file(id), Jason.encode!(kept ++ rows, pretty: true))
  end

  defp load_store do
    [@store, "results", "*.json"] |> Path.join() |> Path.wildcard() |> Enum.flat_map(&(read_json(&1) || []))
  end

  # What is already stored for the rows a run (or import) would write, and
  # the user's call on it. `--overwrite` / `--reuse` answer without asking.
  defp decide(id, keys, verb, opts) do
    have = Enum.filter(cached_rows(id), &(row_key(&1) in keys))

    cond do
      have == [] ->
        :run

      opts[:overwrite] ->
        :run

      opts[:reuse] ->
        :reuse

      true ->
        at = have |> Enum.map(& &1["at"]) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
        host = have |> Enum.map(& &1["host"]) |> Enum.reject(&is_nil/1) |> List.first()
        where = [at && String.slice(at, 0, 16), host] |> Enum.reject(&is_nil/1) |> Enum.join(" on ")

        answer =
          case Mix.shell().prompt("   #{id}: #{length(have)} rows stored (#{where}). #{verb} and overwrite? [y/N]") do
            s when is_binary(s) -> s |> String.trim() |> String.downcase()
            _ -> ""
          end

        if answer in ~w(y yes s sim), do: :run, else: :reuse
    end
  end

  # The report over everything measured so far, fresh rows marked.
  defp finish(updated, opts) do
    all = load_store()
    all == [] && Mix.raise("nothing measured yet in #{@store}/ — run the bench first")
    all = if opts[:rescore], do: Enum.map(all, &rescore/1), else: all

    if opts[:rescore] do
      all |> Enum.group_by(& &1["variant"]) |> Enum.each(fn {id, rs} -> store_rows(id, rs) end)
    end

    md = report(all, updated)
    File.write!(Path.join(@store, "report.md"), md)
    Mix.shell().info("\n" <> md)
  end

  # Rows from the per-run dirs this task used to write
  # (`bench-stt-<ts>/results.json`), stamped with the run's time, into the
  # store — asked about like a re-run.
  defp import_runs(spec, opts) do
    rows =
      Enum.flat_map(String.split(spec, ",", trim: true), fn dir ->
        at =
          case Regex.run(~r/(\d{10})/, dir) do
            [_, ts] -> ts |> String.to_integer() |> DateTime.from_unix!() |> DateTime.to_iso8601()
            _ -> nil
          end

        file = Path.join(dir, "results.json")
        File.exists?(file) || Mix.raise("#{file} not found")

        for r <- Jason.decode!(File.read!(file)),
            do: r |> Map.put_new("at", at) |> Map.put_new("host", "imported")
      end)

    updated =
      rows
      |> Enum.group_by(& &1["variant"])
      |> Enum.flat_map(fn {id, rs} ->
        case decide(id, MapSet.new(rs, &row_key/1), "Import", opts) do
          :run ->
            store_rows(id, rs)
            [id]

          :reuse ->
            []
        end
      end)

    finish(updated, opts)
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
      # No turn_prediction variant: the API reference says it applies "only
      # for models that predict turns", and scribe_v2_realtime — the only
      # realtime model — is not one; the session rejects it.
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

  # Local Whisper. Asked for nothing in particular, the two sizes the local
  # verdict came down to, on whatever backend the sidecar's venv can run,
  # with detection restricted to the corpus languages — the stage setting.
  @default_whisper ["small", "large-v3-turbo"]

  defp whisper_variants(opts) do
    python = sidecar_python()

    models =
      cond do
        opts[:whisper] ->
          String.split(opts[:whisper], ",", trim: true)

        opts[:variants] ->
          []

        File.exists?(python) ->
          @default_whisper

        true ->
          Mix.shell().info("(no local-whisper venv at #{python} — skipping local Whisper; see local-whisper/README.md)")
          []
      end

    if models == [] do
      []
    else
      backend = opts[:whisper_backend] || probe_backend(python)
      threads = opts[:whisper_threads] || if(backend == "faster-whisper", do: System.schedulers_online())
      env = parse_env(opts[:whisper_env])

      env =
        if List.keymember?(env, "WHISPER_LANGUAGES", 0),
          do: env,
          else: [{"WHISPER_LANGUAGES", Enum.join(corpus_languages(), ",")} | env]

      for name <- models do
        model = resolve_model(name, backend)

        %{
          id:
            "whisper-" <> whisper_name(model) <>
              if(threads, do: "@#{threads}t", else: "") <>
              if(opts[:whisper_tag], do: "+#{opts[:whisper_tag]}", else: ""),
          provider: :local_whisper,
          price: :local,
          model: model,
          backend: backend,
          threads: threads,
          sidecar_env: env,
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
    |> String.replace_suffix("-mlx", "")
  end

  # A size name maps onto the mlx-community conversion on the mlx backend;
  # anything with a slash (a repo id, a path) is passed through.
  defp resolve_model(name, "mlx") do
    cond do
      String.contains?(name, "/") -> name
      name == "large-v3-turbo" -> "mlx-community/whisper-large-v3-turbo"
      true -> "mlx-community/whisper-#{name}-mlx"
    end
  end

  defp resolve_model(name, _backend), do: name

  # mlx when the venv can import it (Apple Silicon), CTranslate2 otherwise —
  # never torch, which is the slow one on CPU and segfaults on some ROCm boxes.
  defp probe_backend(python) do
    case System.cmd(python, ["-c", "import mlx_whisper"], stderr_to_stdout: true) do
      {_, 0} -> "mlx"
      _ -> "faster-whisper"
    end
  end

  defp sidecar_python, do: Path.expand(Path.join(@whisper_dir, ".venv/bin/python"))

  defp corpus_languages do
    @manifest |> File.read!() |> Jason.decode!() |> Map.fetch!("clips") |> Enum.map(& &1["lang"]) |> Enum.uniq()
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
            send(relay, {:watch, pid})
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

  # Forwards one client's events to the bench under its variant id, and
  # watches the client so a crash lands on the row as an error instead of as
  # a silently short transcript (the bench traps exits and would otherwise
  # just carry on without it).
  defp relay(bench, id, errored? \\ false) do
    receive do
      {:transcript, _p, text, final?, ts} ->
        send(bench, {:stt_bench, id, if(final?, do: :final, else: :partial), text, ts})
        relay(bench, id, errored?)

      {:stt_error, _p, reason} ->
        Mix.shell().error("   ✗ #{id}: #{inspect(reason) |> String.slice(0, 200)}")
        send(bench, {:stt_bench, id, :error, inspect(reason), System.system_time(:millisecond)})
        relay(bench, id, true)

      {:watch, pid} ->
        Process.monitor(pid)
        relay(bench, id, errored?)

      {:DOWN, _ref, :process, _pid, reason} ->
        # A client that already reported why it is going has said enough.
        unless errored? or reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
          Mix.shell().error("   ✗ #{id} exited: #{inspect(reason) |> String.slice(0, 200)}")
          send(bench, {:stt_bench, id, :error, "client exited: " <> inspect(reason), System.system_time(:millisecond)})
        end

        relay(bench, id, true)

      :stop ->
        :ok

      _ ->
        relay(bench, id, errored?)
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
      events: Enum.map(events, &Tuple.to_list/1),
      # Local engines are only as fast as the machine they ran on.
      at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      host: host()
    }
  end

  defp host do
    {:ok, h} = :inet.gethostname()
    to_string(h)
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
    |> Map.merge(Map.take(r, ["clip", "medley", "standalone", "at", "host"]))
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

  defp boot_sidecar(variants, _opts) do
    case Enum.find(variants, &(&1.provider == :local_whisper)) do
      nil ->
        {variants, :not_started}

      w ->
        Mix.shell().info("   starting whisper sidecar: #{w.model} (#{w.backend || "sidecar default backend"})")
        File.mkdir_p!(Path.join(@store, "logs"))

        sc =
          start_sidecar(w.model, w.backend, Path.join([@store, "logs", "sidecar-#{w.id}.log"]),
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
    python = sidecar_python()
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

  defp report(all, updated) do
    {medleys, results} = Enum.split_with(all, & &1["medley"])
    by_variant = Enum.group_by(results, & &1["variant"])
    langs = results |> Enum.map(& &1["lang"]) |> Enum.uniq() |> Enum.sort()

    medley_by_variant = Enum.group_by(medleys, & &1["variant"])

    rows =
      by_variant
      |> Enum.map(fn {variant, rs} -> summarize(variant, rs, langs, Map.get(medley_by_variant, variant, [])) end)
      |> Enum.sort_by(& &1.wer)

    # The scorecard: one line per engine, numbers a non-specialist can rank.
    card_header =
      "| engine | latency (ms) | accuracy | " <>
        Enum.map_join(langs, " | ", & &1) <> " | multi-language | $/h |"

    card_sep = "|" <> String.duplicate("---|", 5 + length(langs))

    card =
      Enum.map_join(rows, "\n", fn r ->
        "| #{r.variant}#{if r.variant in updated, do: " ✦", else: ""} | #{ms(r.final_p50)} | #{score(r.wer)} | " <>
          Enum.map_join(langs, " | ", &score(r.by_lang[&1])) <>
          " | #{score(r.multi_wer)} | #{price(r.price)} |"
      end)

    header =
      "| variant | WER | " <>
        Enum.map_join(langs, " | ", &"WER #{&1}") <>
        " | lines followed | final lag p50 / p90 | partial lag p50 | reveal delay p50 | $/h | errors | measured |"

    sep = "|" <> String.duplicate("---|", 9 + length(langs))

    body =
      Enum.map_join(rows, "\n", fn r ->
        "| #{r.variant} | #{pct(r.wer)} | " <>
          Enum.map_join(langs, " | ", &pct(r.by_lang[&1])) <>
          " | #{pct(r.followed)} | #{ms(r.final_p50)} / #{ms(r.final_p90)} | #{ms(r.partial_p50)} | #{ms(r.reveal_p50)} | #{price(r.price)} | #{r.errors}" <>
          " | #{measured(r)}#{if r.variant in updated, do: " ✦", else: ""} |"
      end)

    fresh =
      if updated == [],
        do: "",
        else: "\n✦ measured in this run; the other rows are from the store (#{@store}/results/)."

    notes =
      results
      |> Enum.filter(&(&1["errors"] != []))
      |> Enum.map_join("\n", &"- #{&1["variant"]} on #{&1["clip"]}: #{Enum.join(&1["errors"], "; ") |> String.slice(0, 240)}")

    """
    ## STT bench — #{length(Enum.uniq_by(results, & &1["clip"]))} clips, #{Enum.sum(Enum.map(Enum.uniq_by(results, & &1["clip"]), & &1["ref_words"]))} sung words

    **Accuracy** (0–100) = of every 100 words sung, how many came out right; wrong,
    missing and invented words all count against it (100 − word error rate). On sung
    audio, 90+ is excellent, 80–90 follows most lines, below 70 the follower loses the
    song. **Latency** = ms from the last sung word to the final transcript that
    contains it (median; finals gate the stage's reveals). **Multi-language** =
    accuracy inside ONE session that moves pt → it → de → en, where the engine must
    notice each switch on its own. Sorted by accuracy.

    #{card_header}
    #{card_sep}
    #{card}
    #{fresh}

    ### Details

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

  defp score(nil), do: "—"
  defp score(wer), do: to_string(max(0, round((1 - wer) * 100)))

  defp measured(%{at: nil, host: host}), do: host
  defp measured(%{at: at, host: host}), do: String.slice(at, 0, 10) <> " " <> host

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

  defp summarize(variant, rs, langs, medley_rs) do
    wer = fn rs ->
      n = rs |> Enum.map(& &1["ref_words"]) |> Enum.sum()
      if n == 0, do: nil, else: (rs |> Enum.map(& &1["errors_words"]) |> Enum.sum()) / n
    end

    finals = Enum.flat_map(rs, & &1["final_lags"])
    lines = rs |> Enum.map(& &1["lines"]) |> Enum.sum()

    %{
      variant: variant,
      wer: wer.(rs),
      multi_wer: wer.(medley_rs),
      by_lang: Map.new(langs, fn l -> {l, wer.(Enum.filter(rs, &(&1["lang"] == l)))} end),
      followed: if(lines == 0, do: nil, else: (rs |> Enum.map(& &1["lines_confirmed"]) |> Enum.sum()) / lines),
      final_p50: SttBench.pct(finals, 50),
      final_p90: SttBench.pct(finals, 90),
      partial_p50: SttBench.pct(Enum.flat_map(rs, & &1["partial_lags"]), 50),
      reveal_p50: SttBench.pct(Enum.flat_map(rs, & &1["confirm_delays"]), 50),
      price: hd(rs)["price"],
      errors: rs |> Enum.map(&length(&1["errors"])) |> Enum.sum(),
      at: rs |> Enum.map(& &1["at"]) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
      host: rs |> Enum.map(& &1["host"]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.join("/")
    }
  end

  defp pct(nil), do: "—"
  defp pct(x), do: "#{Float.round(x * 100, 1)}%"
  defp ms(nil), do: "—"
  defp ms(x), do: "#{round(x)}"

  defp price(key) do
    case @prices[if(is_binary(key), do: String.to_atom(key), else: key)] do
      {+0.0, _} -> "0 (local)"
      {usd, _} -> "$#{usd}"
      nil -> "?"
    end
  end
end
