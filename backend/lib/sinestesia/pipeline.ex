defmodule Sinestesia.Pipeline do
  @moduledoc """
  Per-socket GenServer. Orchestrates the three rails:

    * receives audio chunks from the socket, fans out to one or more STT providers
    * collects transcripts (tagged with provider), pushes them back to the socket
    * collects expressive features from the socket
    * debounces Director calls (Gemma → image prompt → fal.ai → URL → socket)

  STT provider selection via `STT_PROVIDER` env var:
    "elevenlabs"  → ElevenLabs Scribe v2 Realtime only (default)
    "deepgram"    → Deepgram Nova-3 only
    "both"        → both run in parallel; transcripts logged side-by-side
                    for A/B comparison. The first to deliver each final
                    transcript wins for the Director.
  """
  use GenServer
  require Logger

  # LIVE: no artificial pacing. The next Director fires as soon as the
  # previous cycle finishes (`generating?` already serializes director→image)
  # and new lyrics exist — the cadence bottleneck is generation itself
  # (~2-2.5s), never a pre-fixed wait, so the visuals don't drift behind the
  # song. REPLAY: ~3s simulates a natural live cadence. Override either with
  # DIRECTOR_MIN_INTERVAL_MS (e.g. as a brake if a fast image provider starts
  # flashing elements past too quickly).
  defp director_min_interval_ms do
    base =
      case System.get_env("DIRECTOR_MIN_INTERVAL_MS") do
        nil -> if replay?(), do: 3000, else: 0
        v -> String.to_integer(v)
      end

    # A replay compresses the lyric timeline by REPLAY_SPEED; compress the
    # pacing gate equally, otherwise a 2x replay yields half the images the
    # live performance produced.
    round(base / replay_speed())
  end

  defp replay?, do: System.get_env("STT_PROVIDER") == "replay"

  defp replay_speed do
    with true <- replay?(),
         {s, _} when s > 0 <- Float.parse(System.get_env("REPLAY_SPEED", "1.0")) do
      s
    else
      _ -> 1.0
    end
  end

  ## API

  def start_link(socket_pid) do
    # Only one Pipeline at a time globally. Synchronously stop any previous one
    # so the Registry slot is free before we try to register the new pipeline.
    stop_previous()

    GenServer.start_link(__MODULE__, socket_pid,
      name: {:via, Registry, {Sinestesia.PipelineRegistry, :active}}
    )
  end

  defp stop_previous do
    case Registry.lookup(Sinestesia.PipelineRegistry, :active) do
      [{old_pid, _}] when is_pid(old_pid) ->
        if Process.alive?(old_pid), do: kill_previous(old_pid)

      _ ->
        :ok
    end
  end

  # Robustly take down the old pipeline before starting a new one. We MUST
  # wait until it's actually dead (and deregistered from the Registry),
  # otherwise the new start_link races and falls into {:already_started, _}.
  # That used to make AudioSocket "adopt" a corpse pid.
  #
  # Sequence: monitor → :shutdown → wait up to 4s. If still alive (pipeline
  # may be blocked in init waiting for ElevenSTT WS handshake), hard-kill.
  defp kill_previous(old_pid) do
    Logger.info("pipeline: stopping previous active pipeline #{inspect(old_pid)}")
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^old_pid, _} ->
        :ok
    after
      4_000 ->
        Logger.warning("pipeline: previous didn't die in 4s, hard-killing #{inspect(old_pid)}")
        Process.exit(old_pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^old_pid, _} -> :ok
        after
          1_000 ->
            Logger.error("pipeline: hard-kill timed out for #{inspect(old_pid)}")
            :ok
        end
    end
  end

  def audio_chunk(pid, bin), do: GenServer.cast(pid, {:audio_chunk, bin})
  def expressive(pid, features), do: GenServer.cast(pid, {:expressive, features})
  def fast_features(pid, features), do: GenServer.cast(pid, {:fast_features, features})
  def melody(pid, features), do: GenServer.cast(pid, {:melody, features})
  def set_style(pid, style), do: GenServer.cast(pid, {:set_style, style})
  def set_camera(pid, camera), do: GenServer.cast(pid, {:set_camera, camera})
  def reset_song(pid), do: GenServer.cast(pid, :reset_song)
  def mint(pid, opts \\ %{}), do: GenServer.cast(pid, {:mint, opts})

  # A song ending is one event, not two: snapshot the performance for the mint
  # and immediately clear the canvas so the next song can start singing over it.
  # Ordering matters (mint must see the finished song), so it's one cast.
  def end_song(pid, opts \\ %{}), do: GenServer.cast(pid, {:end_song, opts})

  # Load (or clear) the song's lyrics for predictive look-ahead. `lines` may be a
  # list of lines or one blob with newlines; an empty payload clears the script.
  def set_lyrics(pid, lines), do: GenServer.cast(pid, {:set_lyrics, lines})

  # Push the current Sinestesia.SongLibrary catalog to the socket.
  def list_songs(pid), do: GenServer.cast(pid, :list_songs)

  # Load a known song from the library by id — same effect as pasting its
  # lyrics, plus tracking current_song_id and (if the song has one) its
  # pinned style.
  def load_song(pid, id), do: GenServer.cast(pid, {:load_song, id})

  # Fetch lyrics from a URL (letras.mus.br/.com.br, cifraclub.com.br), save
  # them to the library, and load them. Off the hot path — the fetch runs in
  # a Task so a slow/unreachable site never blocks the pipeline.
  def import_song(pid, url, opts \\ %{}), do: GenServer.cast(pid, {:import_song, url, opts})

  # Save the currently loaded (or explicitly given) lyrics into the library —
  # the "add this song" flow for something sung that wasn't already known.
  def save_song(pid, attrs), do: GenServer.cast(pid, {:save_song, attrs})

  # An ordered list of library song ids for a show. Loading a setlist loads
  # its FIRST song immediately (same eager-bootstrap head start as `load_song`
  # alone); end_song/reset_song auto-advance to the next id while one is active.
  def load_setlist(pid, ids), do: GenServer.cast(pid, {:load_setlist, ids})

  ## Callbacks

  @impl true
  def init(socket_pid) do
    Process.flag(:trap_exit, true)
    providers = which_providers()
    stts = start_stts(providers, socket_pid)

    {:ok,
     %{
       socket: socket_pid,
       stts: stts,
       lyrics: [],
       # How many committed lines the Director has already been given.
       # See unsent_text/2: without this, lines committed while an image was
       # rendering were silently skipped.
       lyrics_sent: 0,
       last_finals: %{},
       last_interims: %{},
       last_text_at: %{},
       last_director_text: "",
       style: Sinestesia.Director.default_style(),
       style_locked?: false,
       final_lyric_count: 0,
       director_conversation: Sinestesia.Director.init_conversation(),
       expressive: %{},
       # Latest realtime melody descriptor (FE `melody` message). Stamped onto
       # the next Director call; ages out after 6s. See melody_hint/1.
       melody: %{},
       fast: %{},
       # Per-song provenance log: one entry per Director prompt, newest-first,
       # each %{ts: iso8601, prompt: raw_director_output}. Joined with the
       # accumulated `lyrics` transcript at song end to build the hash that
       # proves the NFT was made in that exact live moment. Reset each song.
       performance_steps: [],
       # Every generated frame URL in order — the song's visual evolution. At
       # mint time these are composed into the animated GIF / collage that
       # becomes the NFT image (so it captures the whole song, not just the last
       # frame). Reset each song.
       frame_urls: [],
       last_director_at: 0,
       last_audio_chunk_at: 0,
       last_stt_ms: nil,
       last_stt_provider: nil,
       generating?: false,
       since_last_director: false,
       last_image_url: nil,
       # Route/model that rendered the last frame. Carried in state because the
       # provider records it inside the image TASK's process dictionary, which
       # the mint (running here, in the GenServer) cannot see.
       last_image_route: nil,
       bootstrap_done?: false,
       # Story mode: the style text is appended to the Director's prompt only
       # until one styled image lands (bootstrap / after a style change). From
       # then on img2img inherits the look visually — repeating the style text
       # every frame re-applies it to the whole canvas and drags the image
       # toward the style's fixed point (flat shapes, etc).
       style_stamped?: false,
       frames_since_style: 0,
       # Last 3 inpaint placements — used to redirect the Director's POS when
       # it would repaint (and erase) a region that was just painted.
       recent_placements: [],
       # Operator-driven virtual camera (zoom/pan_x/pan_y, -1..1). Persistent
       # velocity: applied by the image sidecar to every generated frame while
       # non-neutral. Set via the `camera` WS message; neutral on reset.
       camera: neutral_camera(),
       # Bumped on every reset_song. Any in-flight Task (director / image /
       # curator) captures the session_id at spawn; results carrying an older
       # session_id are dropped on receive so old-song work can't leak into
       # the new song. Belt + suspenders alongside pending_pids below.
       session_id: 0,
       # PIDs of every in-flight Task (director / image / curator). Killed
       # on reset so we stop paying fal.ai / running Gemma for old-song work.
       pending_pids: MapSet.new(),
       # Predictive look-ahead (SPECULATIVE_LOOKAHEAD): the song's lyrics pasted
       # by the operator, so we can render the NEXT line ahead of the singer.
       # `script_cursor` is the index of the last CONFIRMED (actually sung) line,
       # -1 before the song starts. `speculation` holds the one look-ahead frame
       # being rendered/held for `script_cursor + 1`; see maybe_speculate/1.
       script: [],
       script_active?: false,
       script_cursor: -1,
       speculation: nil,
       # Set when the current script came from Sinestesia.SongLibrary (loaded
       # explicitly via `load_song`, auto-identified, or advanced to from a
       # setlist) — nil for a raw paste. Lets the frontend show "identified as
       # X" and is where a future timing-capture/"save this song" flow would
       # hang the recorded session off of.
       current_song_id: nil,
       # An ordered list of library song ids for a show (`load_setlist`).
       # `setlist_index` is which one is CURRENT; end_song/reset_song advance
       # it and load the next id while a setlist is active (`setlist != []`).
       setlist: [],
       setlist_index: 0,
       # Deep look-ahead (LOOKAHEAD_DEPTH > 1): a SEPARATE background chain from
       # `speculation` above. Rendering is inherently sequential (i2i needs the
       # previous frame), so this is one chain, not fan-out: `prerender` is the
       # one background render currently in flight (same shape as `speculation`
       # but its result lands in `prerendered`, never revealed directly);
       # `prerendered` is a cache, keyed by script line index, of frames rendered
       # further ahead than the active `speculation` slot. `speculate_next/1`
       # checks this cache before spawning a fresh render — see
       # maybe_deepen_lookahead/1. At LOOKAHEAD_DEPTH=1 (default) this whole
       # mechanism never activates; the pipeline behaves exactly as Phase 1/2.
       prerender: nil,
       prerendered: %{},
       # Eager bootstrap (SPECULATIVE_LOOKAHEAD): the reactive bootstrap gate
       # normally waits for @bootstrap_min_words of REAL singing before it will
       # render the opening frame — but if the operator has already pasted the
       # whole song, there's no reason to wait: this renders the opening from
       # the SCRIPT's own first words the moment lyrics load, and holds it
       # until real singing actually reaches the same word threshold. See
       # maybe_speculate_bootstrap/1, reveal_bootstrap_speculation/1.
       bootstrap_speculation: nil,
       # A lyrics reload mid-song discards + re-arms the eager bootstrap WITHOUT
       # bumping session_id (that's reserved for a whole new performance) —
       # so a stale result from the discarded attempt could otherwise slip
       # through if Process.exit(:kill) loses the race against an
       # already-in-flight `send` from the old Task. Bumped every time a fresh
       # eager-bootstrap render actually starts; carried in its messages and
       # checked alongside session_id, same belt-and-suspenders pattern.
       bootstrap_generation: 0,
       # Musical structure (MUSICAL_STRUCTURE): verse/chorus/bridge/outro derived
       # from the pasted lyrics (blank lines = stanza breaks). `current_section`
       # is the section id covering `script_cursor`, updated alongside it — see
       # update_position/2. Independent of look-ahead: works whenever lyrics are
       # loaded, even with SPECULATIVE_LOOKAHEAD off.
       structure: Sinestesia.MusicalStructure.analyze(nil),
       current_section: nil,
       # Smoothed tempo estimate from Rail 1 (`fast_features`, onset intervals),
       # for the structure HUD and (loosely) to corroborate section timing. Never
       # feeds provenance — it is a best-effort atmosphere signal, not a fact.
       tempo_bpm: nil,
       tempo_at: 0
     }}
  end

  @impl true
  def handle_cast({:audio_chunk, bin}, %{stts: stts} = state) do
    Enum.each(stts, fn {provider, pid} -> send_audio(provider, pid, bin) end)
    {:noreply, %{state | last_audio_chunk_at: System.system_time(:millisecond)}}
  end

  def handle_cast({:expressive, f}, state) do
    {:noreply, %{state | expressive: f} |> maybe_trigger()}
  end

  def handle_cast({:fast_features, f}, state) do
    prev = %{bpm: state.tempo_bpm, at: state.tempo_at}
    next = Sinestesia.Tempo.smooth(prev, Map.get(f, "tempo_estimate"), now_ms())
    state = %{state | fast: f, tempo_bpm: next.bpm, tempo_at: next.at}

    # Only worth telling the HUD when the DISPLAYED number actually moves, and
    # only when there is a section to report against — otherwise this is silent
    # bookkeeping (still useful: it corroborates section timing at mint/debug
    # time via state.tempo_bpm, never provenance).
    state =
      if structure_enabled?() and not is_nil(state.current_section) and
           Sinestesia.Tempo.display(next) != Sinestesia.Tempo.display(prev) do
        section = Enum.at(state.structure.sections, state.current_section)

        push(
          state.socket,
          structure_msg(section, state.script_cursor, Sinestesia.Tempo.display(next))
        )

        state
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:melody, f}, state) when is_map(f) do
    # Stamp server time on arrival — melody_hint/1 ages it against now_ms(),
    # so we can't trust a (possibly skewed or missing) client clock.
    {:noreply, %{state | melody: Map.put(f, "ts", now_ms())}}
  end

  def handle_cast({:melody, _}, state), do: {:noreply, state}

  def handle_cast({:set_style, raw_style}, state) do
    apply_style(state, raw_style, _from_curator? = false)
  end

  def handle_cast({:set_camera, raw}, state) do
    camera = sanitize_camera(raw)
    Logger.info("[camera] #{inspect(camera)}")
    {:noreply, %{state | camera: camera}}
  end

  # Operator pasted (or cleared) the song's lyrics. Reloading mid-song drops the
  # position and any look-ahead in flight and re-acquires from wherever the
  # singing currently is.
  def handle_cast({:set_lyrics, raw}, state) do
    {:noreply, load_lyrics(state, raw, "[lyrics]") |> Map.put(:current_song_id, nil)}
  end

  def handle_cast(:list_songs, state) do
    push(state.socket, %{type: "songs", songs: Sinestesia.SongLibrary.list()})
    {:noreply, state}
  end

  def handle_cast({:load_song, id}, state) do
    case Sinestesia.SongLibrary.get(id) do
      nil ->
        push(state.socket, %{type: "song_error", message: "unknown song #{inspect(id)}"})
        {:noreply, state}

      song ->
        Logger.info("[song-library] loading #{song.title}#{artist_suffix(song.artist)}")

        # A song can pin the visual style it was designed/rendered with. Apply
        # it BEFORE load_lyrics: apply_style/3 resets director_conversation,
        # and load_lyrics's maybe_speculate_bootstrap/1 immediately spawns a
        # Director call against whatever conversation exists at that moment —
        # applying style after would mean the eager render (and whatever
        # conversation it hands back on reveal) reflects the OLD style.
        {:noreply, state} =
          if song.style, do: apply_style(state, song.style, false), else: {:noreply, state}

        state =
          state
          |> load_lyrics(song.lyrics_text, "[song] #{song.title}")
          |> Map.put(:current_song_id, song.id)

        push(state.socket, %{
          type: "song_loaded",
          id: song.id,
          title: song.title,
          artist: song.artist
        })

        {:noreply, state}
    end
  end

  def handle_cast({:import_song, url, opts}, state) do
    parent = self()
    sid = state.session_id

    Task.start(fn ->
      result = Sinestesia.LyricsImport.import(url)
      send(parent, {:song_imported, result, url, opts, sid})
    end)

    {:noreply, state}
  end

  def handle_cast({:save_song, attrs}, state) do
    lyrics_text =
      cond do
        is_binary(Map.get(attrs, "lyrics_text")) and Map.get(attrs, "lyrics_text") != "" ->
          Map.get(attrs, "lyrics_text")

        state.script != [] ->
          Enum.join(state.script, "\n")

        true ->
          Enum.join(state.lyrics, "\n")
      end

    save_attrs = %{
      id: presence(Map.get(attrs, "id")),
      title: Map.get(attrs, "title"),
      artist: presence(Map.get(attrs, "artist")),
      style: presence(Map.get(attrs, "style")) || state.style,
      source_url: presence(Map.get(attrs, "source_url")),
      lyrics_text: lyrics_text
    }

    case Sinestesia.SongLibrary.save(save_attrs) do
      {:ok, song} ->
        Logger.info("[song-library] saved #{song.title}#{artist_suffix(song.artist)}")

        push(state.socket, %{
          type: "song_saved",
          id: song.id,
          title: song.title,
          artist: song.artist
        })

        {:noreply, %{state | current_song_id: song.id}}

      {:error, reason} ->
        push(state.socket, %{type: "song_error", message: "could not save: #{inspect(reason)}"})
        {:noreply, state}
    end
  end

  def handle_cast({:load_setlist, ids}, state) when is_list(ids) do
    Logger.info("[setlist] loaded #{length(ids)} song(s)")
    state = %{state | setlist: ids, setlist_index: 0}
    {:noreply, load_setlist_song(state, 0)}
  end

  # Reset all song-scoped state but KEEP open STT connections + socket.
  # Use when a new song starts mid-session — avoids reconnect roundtrip.
  # In-flight tasks from the previous song are invalidated via session_id.
  def handle_cast(:reset_song, state) do
    # Lyrics (if loaded) persist across a reset — start the NEXT song's opening
    # render immediately too, same as if they'd just been pasted fresh.
    {:noreply, state |> reset_song_state() |> maybe_speculate_bootstrap()}
  end

  # Song over: mint what was just painted AND start the next song in one step.
  # The mint task takes its own snapshot of the song, so resetting immediately
  # after is safe — and necessary, because the singer is already starting again.
  def handle_cast({:end_song, opts}, state) do
    case state.last_image_url do
      nil ->
        # Nothing was painted, so there's nothing to mint — but the reset still
        # has to happen, otherwise "End Song" would silently do nothing.
        push(state.socket, %{type: "mint_error", message: "nothing painted yet", ts: now_ms()})

      image_url ->
        spawn_mint(state, image_url, opts)
        push(state.socket, %{type: "mint_status", status: "minting", ts: now_ms()})
    end

    # A completed song is exactly when a setlist should move on; a plain
    # `reset_song` (soundcheck/false start, no mint) replays the SAME entry
    # instead — see that handler above.
    {:noreply, state |> reset_song_state() |> advance_setlist_or_rearm()}
  end

  # Mint the finished painting: store on Walrus + mint the master on Sui via the
  # mint sidecar, then push the claim URL for the QR overlay. Async so the show
  # never blocks on chain latency. `opts` may carry song/artist/venue overrides.
  def handle_cast({:mint, opts}, state) do
    case state.last_image_url do
      nil ->
        push(state.socket, %{type: "mint_error", message: "nothing painted yet", ts: now_ms()})
        {:noreply, state}

      image_url ->
        spawn_mint(state, image_url, opts)
        push(state.socket, %{type: "mint_status", status: "minting", ts: now_ms()})
        {:noreply, state}
    end
  end

  defp reset_song_state(state) do
    new_session = state.session_id + 1
    killed = kill_pending(state.pending_pids)

    Logger.info(
      "[pipeline] song reset — session_id #{state.session_id} → #{new_session}, killed #{killed} in-flight task(s)"
    )

    # Tell stateful STT providers (local Whisper) to drop their audio buffer
    # and re-detect the language for the new song.
    Enum.each(state.stts, fn {provider, pid} -> reset_stt(provider, pid) end)

    default_style = Sinestesia.Director.default_style()

    push(state.socket, %{
      type: "style",
      style: default_style,
      source: "reset",
      ts: now_ms()
    })

    %{
      state
      | lyrics: [],
        lyrics_sent: 0,
        last_finals: %{},
        last_interims: %{},
        last_text_at: %{},
        last_director_text: "",
        style: default_style,
        style_locked?: false,
        final_lyric_count: 0,
        director_conversation: Sinestesia.Director.init_conversation(),
        performance_steps: [],
        frame_urls: [],
        last_director_at: 0,
        last_stt_ms: nil,
        last_stt_provider: nil,
        # Critical: clear generating? so the next director call isn't blocked
        # waiting for an in-flight (now-stale) task that we're about to drop.
        generating?: false,
        since_last_director: false,
        last_image_url: nil,
        last_image_route: nil,
        bootstrap_done?: false,
        style_stamped?: false,
        frames_since_style: 0,
        recent_placements: [],
        melody: %{},
        camera: neutral_camera(),
        session_id: new_session,
        pending_pids: MapSet.new(),
        # Keep the pasted lyrics AND structure across a reset (rehearsing the
        # same song is common, and a stale script simply degrades to reactive),
        # but drop the position and any in-flight look-ahead — new performance.
        script_cursor: -1,
        speculation: nil,
        prerender: nil,
        prerendered: %{},
        bootstrap_speculation: nil,
        current_section: nil
    }
  end

  defp neutral_camera, do: %{zoom: 0.0, pan_x: 0.0, pan_y: 0.0}

  # Clamp each axis to -1..1 and drop anything else the client sent. Accepts
  # ints, floats, or missing keys (missing = 0.0, so a partial message like
  # %{"zoom" => -1} stops any previous pan).
  defp sanitize_camera(raw) when is_map(raw) do
    take = fn key ->
      case Map.get(raw, key, 0) do
        v when is_number(v) -> v |> max(-1) |> min(1) |> :erlang.float()
        _ -> 0.0
      end
    end

    %{zoom: take.("zoom"), pan_x: take.("pan_x"), pan_y: take.("pan_y")}
  end

  defp sanitize_camera(_), do: neutral_camera()

  defp kill_pending(pids) do
    Enum.reduce(pids, 0, fn pid, acc ->
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
        acc + 1
      else
        acc
      end
    end)
  end

  # Sweep out PIDs that have already completed. Called from each handle_info
  # so the set doesn't grow unbounded across a long session.
  defp drop_dead(pids) do
    pids |> Enum.filter(&Process.alive?/1) |> Enum.into(MapSet.new())
  end

  @impl true
  def handle_info({:transcript, provider, text, is_final, recv_ts}, state) do
    # No audio flows in replay mode (last_audio_chunk_at stays 0) — latency is
    # only meaningful relative to a real chunk.
    latency =
      if state.last_audio_chunk_at > 0, do: recv_ts - state.last_audio_chunk_at

    tag = if is_final, do: "FIN", else: "int"

    Logger.info("[#{provider}] #{tag} +#{latency || 0}ms: #{text}")

    push(state.socket, %{
      type: "transcript",
      provider: provider,
      text: text,
      is_final: is_final,
      latency_ms: latency,
      ts: recv_ts
    })

    state = update_text_state(state, provider, text, is_final, latency)
    state = maybe_auto_identify(state, is_final)

    # Predictive look-ahead: a confirmed line tells us where the singer actually
    # is. Advance the script cursor and, if we already rendered this line ahead
    # of time, reveal it now. `:handled` means the look-ahead path fully serviced
    # this line; otherwise fall through to the reactive Director.
    case advance_script(state, text, is_final) do
      {state, :handled} -> {:noreply, state}
      {state, :fallthrough} -> {:noreply, maybe_trigger(state)}
    end
  end

  # Replay sessions can carry the style they were recorded with.
  def handle_info({:replay_style, style}, state) do
    apply_style(state, style, _from_curator? = false)
  end

  # Replay sessions can carry the song's lyrics (flat list, or raw text with
  # blank lines for structure), so predictive look-ahead AND structure detection
  # can both be exercised headlessly. Same effect as the operator sending `lyrics`.
  def handle_info({:replay_lyrics, raw}, state) do
    {:noreply, load_lyrics(state, raw, "[lyrics] replay")}
  end

  def handle_info({:song_imported, _result, _url, _opts, sid}, %{session_id: cur} = state)
      when sid != cur do
    {:noreply, state}
  end

  def handle_info({:song_imported, {:ok, imported}, url, opts, _sid}, state) do
    save_attrs = %{
      title: presence(Map.get(opts, "title")) || imported.title || "Untitled",
      artist: presence(Map.get(opts, "artist")) || imported.artist,
      source_url: url,
      lyrics_text: imported.lyrics_text
    }

    case Sinestesia.SongLibrary.save(save_attrs) do
      {:ok, song} ->
        Logger.info(
          "[song-library] imported #{song.title}#{artist_suffix(song.artist)} from #{url}"
        )

        push(state.socket, %{
          type: "song_saved",
          id: song.id,
          title: song.title,
          artist: song.artist
        })

        state =
          if Map.get(opts, "load", true) do
            state
            |> load_lyrics(song.lyrics_text, "[song] #{song.title}")
            |> Map.put(:current_song_id, song.id)
          else
            state
          end

        {:noreply, state}

      {:error, reason} ->
        push(state.socket, %{
          type: "song_error",
          message: "could not save imported song: #{inspect(reason)}"
        })

        {:noreply, state}
    end
  end

  def handle_info({:song_imported, {:error, reason}, url, _opts, _sid}, state) do
    Logger.warning("[song-library] import failed for #{url}: #{inspect(reason)}")
    push(state.socket, %{type: "song_error", message: "import failed: #{inspect(reason)}"})
    {:noreply, state}
  end

  # Forwarded so the headless replay task (and optionally the front) knows the
  # session finished. The browser ignores unknown message types per PROTOCOL.md.
  def handle_info({:replay_done, name}, state) do
    push(state.socket, %{type: "replay_done", name: name, ts: now_ms()})
    {:noreply, state}
  end

  def handle_info({:stt_error, provider, reason}, state) do
    push(state.socket, %{
      type: "error",
      provider: provider,
      message: "#{provider}: #{inspect(reason)}"
    })

    {:noreply, state}
  end

  def handle_info(
        {:director_done, _result, _started_at, _call_ms, _model, sid},
        %{session_id: cur} = state
      )
      when sid != cur do
    Logger.info("[director] dropping stale result (session #{sid} ≠ #{cur})")
    {:noreply, state}
  end

  def handle_info(
        {:director_done, {:ok, raw, new_conversation}, started_at, call_ms, director_model, _sid},
        state
      ) do
    # `call_ms` is the provider round-trip measured inside the task; the gap up to
    # now is time the reply spent queued in this GenServer's mailbox. Reporting
    # the sum as "director" latency (the old behaviour) blamed the provider for
    # our own backpressure, so keep them separate.
    director_ms = call_ms
    queue_ms = max(now_ms() - started_at - call_ms, 0)
    {prompt, extra, state} = compose_image_request(raw, state)

    Logger.info(
      "[director] +#{director_ms}ms (queue #{queue_ms}ms) (#{turn_count(new_conversation)} turns)#{compose_tag(extra)}: #{prompt}"
    )

    timings = %{
      stt_ms: state.last_stt_ms,
      stt_provider: state.last_stt_provider,
      director_ms: director_ms,
      director_queue_ms: queue_ms,
      # The lyric window that produced this prompt — carried through to the
      # image message so the front can show what the Director was reacting to.
      lyric: state.last_director_text,
      # Verifiable-inference receipt when the Director ran on 0G Compute (nil
      # otherwise). Rides along to the image message for the on-screen badge.
      verification: Sinestesia.Verifiability.last()
    }

    img_pid =
      spawn_image(prompt, timings, state.last_image_url, state.session_id, state.camera, extra)

    pids =
      state.pending_pids
      |> drop_dead()
      |> MapSet.put(img_pid)

    # Record this prompt in the provenance log (newest-first). `raw` is the
    # Director's literal output — the "director prompt" the NFT hash attests to.
    # The model that produced it rides along: a certificate of authenticity has
    # to say WHICH model wrote each prompt, and the chain can fall back mid-song.
    # `lyric` is the half of the exchange that was missing: a certificate should
    # show the conversation (what the singer sang -> what the Director answered),
    # not just the Director's side. `verification` is the 0G receipt for THIS
    # call, so each prompt can be tied to its own TEE signature rather than to a
    # single song-level claim. It may still be settling here; the mint resolves
    # any pending ones before hashing.
    step = %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      lyric: state.last_director_text,
      prompt: raw,
      model: director_model,
      verification: Sinestesia.Verifiability.last()
    }

    {:noreply,
     %{
       state
       | generating?: true,
         director_conversation: new_conversation,
         bootstrap_done?: true,
         performance_steps: [step | state.performance_steps],
         pending_pids: pids
     }}
  end

  def handle_info({:director_done, {:error, reason}, _started_at, _call_ms, _model, _sid}, state) do
    Logger.warning("[director] error: #{inspect(reason)}")
    {:noreply, %{state | generating?: false, pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info({:mint_done, {:ok, body}}, state) do
    Logger.info("[mint] released #{inspect(Map.get(body, "releaseRef"))}")

    push(state.socket, %{
      type: "mint",
      releaseRef: Map.get(body, "releaseRef"),
      masterTokenId: Map.get(body, "masterTokenId"),
      txId: Map.get(body, "txId"),
      explorerUrl: Map.get(body, "explorerUrl"),
      provenanceHash: Map.get(body, "provenanceHash"),
      traits: Map.get(body, "traits"),
      imageUri: Map.get(body, "imageUri"),
      claimUrl: Map.get(body, "claimUrl"),
      song: Map.get(body, "song"),
      artist: Map.get(body, "artist"),
      ts: now_ms()
    })

    {:noreply, state}
  end

  def handle_info({:mint_done, {:error, reason}}, state) do
    Logger.warning("[mint] failed: #{inspect(reason)}")
    push(state.socket, %{type: "mint_error", message: mint_error_msg(reason), ts: now_ms()})
    {:noreply, state}
  end

  def handle_info({:image_done, _result, _timings, sid}, %{session_id: cur} = state)
      when sid != cur do
    Logger.info("[image] dropping stale result (session #{sid} ≠ #{cur})")
    {:noreply, state}
  end

  def handle_info({:image_done, {:ok, url, frames, prompt}, timings, _sid}, state) do
    out = image_out(url, frames, prompt, timings)

    Logger.info(
      "[image:#{out.label}] +#{out.image_ms}ms (morph #{out.morph_ms}ms, queue #{out.queue_ms}ms) (total #{out.total}ms = stt #{timings.stt_ms || 0} + director #{timings.director_ms} + dirq #{out.dir_queue_ms} + image #{out.image_ms} + morph #{out.morph_ms} + imgq #{out.queue_ms})"
    )

    push(state.socket, out.msg)

    # On-chain settlement finishes after the answer is already on screen, so the
    # receipt above goes out as "pending". Chase the settled result and push it,
    # otherwise the badge sits on "verification pending" for the whole show.
    resolve_verification(out.receipt, state.socket)

    new_state =
      %{
        state
        | generating?: false,
          last_image_url: url,
          last_image_route: out.route || state.last_image_route,
          frame_urls: state.frame_urls ++ [url],
          style_stamped?: true,
          pending_pids: drop_dead(state.pending_pids)
      }

    # Canvas just advanced — if lyrics are loaded, start rendering the next line
    # ahead of the singer.
    {:noreply, maybe_speculate(new_state)}
  end

  def handle_info({:image_done, {:error, reason}, timings, _sid}, state) do
    # A bare `%Req.TransportError{reason: :timeout}` is unactionable: it doesn't
    # say which provider, which route, which model, how long we waited, or what
    # we sent. Report the whole attempt — the interesting failures are the ones
    # where t2i works and i2i doesn't, and that's only visible from here.
    Logger.warning("""
    [image] FAILED #{route_of(timings)}
      error:  #{inspect(reason)}
      after:  #{Map.get(timings, :image_call_ms, "?")}ms
      input:  #{Map.get(timings, :image_input, "?")}
      prompt: #{Map.get(timings, :prompt_chars, "?")} chars
      #{diagnosis(reason, timings)}\
    """)

    {:noreply, %{state | generating?: false, pending_pids: drop_dead(state.pending_pids)}}
  end

  # ── Predictive look-ahead: speculative Director / image ────────────────────
  # A speculative cycle renders the NEXT (predicted) line while the singer is
  # still on the current one, then HOLDS the frame. It is revealed by
  # reveal_speculation/1 only once STT confirms the line was actually sung, so
  # the audience never sees the future and the frame stays honestly "live".

  def handle_info({:spec_director_done, _r, _s, _c, _m, sid, _i}, %{session_id: cur} = state)
      when sid != cur do
    {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info({:spec_director_done, result, started_at, call_ms, model, _sid, index}, state) do
    case state.speculation do
      %{index: ^index, status: :director} = spec ->
        case result do
          {:ok, raw, new_conversation} ->
            # Build the image request against a COPY of the state: the placement
            # / style-refresh bookkeeping it mutates is captured as a delta and
            # only applied if this speculation is confirmed (see reveal). If it's
            # discarded, none of it ever happened.
            {prompt, extra, state2} = compose_image_request(raw, state)
            queue_ms = max(now_ms() - started_at - call_ms, 0)
            receipt = Sinestesia.Verifiability.last()

            timings = %{
              stt_ms: state.last_stt_ms,
              stt_provider: state.last_stt_provider,
              director_ms: call_ms,
              director_queue_ms: queue_ms,
              lyric: spec.line,
              verification: receipt
            }

            step = %{
              ts: DateTime.utc_now() |> DateTime.to_iso8601(),
              lyric: spec.line,
              prompt: raw,
              model: model,
              verification: receipt
            }

            pid =
              spawn_spec_image(
                prompt,
                timings,
                state.last_image_url,
                state.session_id,
                state.camera,
                extra,
                index
              )

            spec2 = %{
              spec
              | status: :image,
                pid: pid,
                new_conv: new_conversation,
                step: step,
                receipt: receipt,
                state_delta: %{
                  recent_placements: state2.recent_placements,
                  frames_since_style: state2.frames_since_style
                }
            }

            {:noreply,
             %{
               state
               | speculation: spec2,
                 pending_pids: MapSet.put(drop_dead(state.pending_pids), pid)
             }}

          {:error, reason} ->
            # Drop the look-ahead; the confirming STT line already set
            # since_last_director, so the reactive path renders it on the next tick.
            Logger.debug("[spec] director error (#{inspect(reason)}); dropping look-ahead")
            {:noreply, discard_speculation(state)}
        end

      _ ->
        # Speculation was discarded or replaced while this was in flight.
        {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
    end
  end

  def handle_info({:spec_image_done, _r, _t, sid, _i}, %{session_id: cur} = state)
      when sid != cur do
    {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info({:spec_image_done, {:ok, url, frames, prompt}, timings, _sid, index}, state) do
    case state.speculation do
      %{index: ^index, status: :image} = spec ->
        out = image_out(url, frames, prompt, timings)

        spec2 = %{
          spec
          | status: :ready,
            frame_msg: out.msg,
            frame_url: url,
            frame_route: out.route
        }

        state = %{state | speculation: spec2, pending_pids: drop_dead(state.pending_pids)}

        if spec.confirmed do
          # The singer already reached this line while it was rendering — reveal
          # now. reveal_speculation -> maybe_speculate -> speculate_next already
          # tries to deepen the chain further, so no separate call needed here.
          {:noreply, reveal_speculation(state)}
        else
          Logger.debug("[spec] line #{index} ready, holding for confirmation")
          # The active speculation just became a valid frontier (it has a
          # frame_url now) — see if LOOKAHEAD_DEPTH allows racing one line deeper.
          {:noreply, maybe_deepen_lookahead(state)}
        end

      _ ->
        {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
    end
  end

  def handle_info({:spec_image_done, {:error, reason}, timings, _sid, index}, state) do
    Logger.warning(
      "[spec] image FAILED #{route_of(timings)} (#{inspect(reason)}); dropping look-ahead"
    )

    case state.speculation do
      %{index: ^index} -> {:noreply, discard_speculation(state)}
      _ -> {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
    end
  end

  # ── Eager bootstrap: pre-render the opening from pasted lyrics ─────────────
  # See maybe_speculate_bootstrap/1. Held in `state.bootstrap_speculation`
  # (never `speculation` — that slot means "canvas exists, looking ahead one
  # line"; this one means "no canvas yet, but the whole song is known").

  # `gen` guards against a subtler race than `sid` alone can: a lyrics reload
  # mid-song discards + re-arms this WITHOUT bumping session_id (that's
  # reserved for a whole new performance) — so if Process.exit(:kill) loses
  # the race against an already-in-flight `send` from the discarded attempt,
  # `sid == cur` would still match. `gen` catches that case.
  def handle_info(
        {:bootstrap_spec_director_done, _r, _s, _c, _m, sid, gen},
        %{session_id: cur, bootstrap_generation: curgen} = state
      )
      when sid != cur or gen != curgen do
    {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info(
        {:bootstrap_spec_director_done, {:ok, raw, new_conversation}, _started_at, _call_ms,
         model, _sid, _gen},
        state
      ) do
    case state.bootstrap_speculation do
      %{status: :director} = bs ->
        {prompt, extra, state2} = compose_image_request(raw, state)
        receipt = Sinestesia.Verifiability.last()

        timings = %{
          stt_ms: nil,
          stt_provider: nil,
          director_ms: 0,
          director_queue_ms: 0,
          lyric: bs.text,
          verification: receipt
        }

        step = %{
          ts: DateTime.utc_now() |> DateTime.to_iso8601(),
          lyric: bs.text,
          prompt: raw,
          model: model,
          verification: receipt
        }

        pid =
          spawn_bootstrap_image(
            prompt,
            timings,
            state.session_id,
            state.bootstrap_generation,
            state2.camera,
            extra
          )

        bs2 = %{
          bs
          | status: :image,
            pid: pid,
            new_conv: new_conversation,
            step: step,
            receipt: receipt,
            state_delta: %{
              recent_placements: state2.recent_placements,
              frames_since_style: state2.frames_since_style
            }
        }

        {:noreply,
         %{
           state
           | bootstrap_speculation: bs2,
             pending_pids: MapSet.put(drop_dead(state.pending_pids), pid)
         }}

      _ ->
        # Discarded (lyrics reloaded) while this was in flight.
        {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
    end
  end

  def handle_info(
        {:bootstrap_spec_director_done, {:error, reason}, _started_at, _call_ms, _model, _sid,
         _gen},
        state
      ) do
    Logger.debug(
      "[bootstrap-spec] director error (#{inspect(reason)}); falling back to the reactive bootstrap"
    )

    {:noreply, %{state | bootstrap_speculation: nil, pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info(
        {:bootstrap_spec_image_done, _r, _t, sid, gen},
        %{session_id: cur, bootstrap_generation: curgen} = state
      )
      when sid != cur or gen != curgen do
    {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info(
        {:bootstrap_spec_image_done, {:ok, url, frames, prompt}, timings, _sid, _gen},
        state
      ) do
    case state.bootstrap_speculation do
      %{status: :image} = bs ->
        out = image_out(url, frames, prompt, timings)
        ready = %{bs | status: :ready, frame_msg: out.msg, frame_url: url, frame_route: out.route}

        state = %{
          state
          | bootstrap_speculation: ready,
            pending_pids: drop_dead(state.pending_pids)
        }

        if ready.confirmed do
          # Real singing already reached the threshold while this was still
          # rendering — reveal now.
          {:noreply, reveal_bootstrap_speculation(state)}
        else
          Logger.debug("[bootstrap-spec] opening frame ready, holding for enough real singing")
          {:noreply, state}
        end

      _ ->
        {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
    end
  end

  def handle_info({:bootstrap_spec_image_done, {:error, reason}, timings, _sid, _gen}, state) do
    Logger.warning(
      "[bootstrap-spec] image FAILED #{route_of(timings)} (#{inspect(reason)}); falling back to the reactive bootstrap"
    )

    {:noreply, %{state | bootstrap_speculation: nil, pending_pids: drop_dead(state.pending_pids)}}
  end

  # ── Deep look-ahead (LOOKAHEAD_DEPTH > 1): background prerender chain ──────
  # Separate from the speculation slot above. Results never reveal directly —
  # they land in `state.prerendered`, and `speculate_next/1` promotes them into
  # the (already-tested) speculation slot when the singer's confirmed position
  # reaches them. See maybe_deepen_lookahead/1 for how the chain advances.

  def handle_info(
        {:prerender_director_done, _r, _s, _c, _m, sid, _i, _seed, _delta},
        %{session_id: cur} = state
      )
      when sid != cur do
    {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info(
        {:prerender_director_done, {:ok, raw, new_conversation}, _started_at, _call_ms, model,
         _sid, index, seed_url, seed_delta},
        state
      ) do
    case state.prerender do
      %{index: ^index, status: :director} = pr ->
        # Compose against a VIEW of state with the frontier's accumulated
        # placement/style bookkeeping overlaid — the confirmed state.recent_placements
        # etc. are behind the frontier by however deep this chain already runs.
        view = Map.merge(state, seed_delta || %{})
        {prompt, extra, view2} = compose_image_request(raw, view)
        receipt = Sinestesia.Verifiability.last()

        timings = %{
          stt_ms: nil,
          stt_provider: nil,
          director_ms: 0,
          director_queue_ms: 0,
          lyric: pr.line,
          verification: receipt
        }

        step = %{
          ts: DateTime.utc_now() |> DateTime.to_iso8601(),
          lyric: pr.line,
          prompt: raw,
          model: model,
          verification: receipt
        }

        pid =
          spawn_prerender_image(
            prompt,
            timings,
            seed_url,
            state.session_id,
            state.camera,
            extra,
            index
          )

        pr2 = %{
          pr
          | status: :image,
            pid: pid,
            new_conv: new_conversation,
            step: step,
            receipt: receipt,
            state_delta: %{
              recent_placements: view2.recent_placements,
              frames_since_style: view2.frames_since_style
            }
        }

        {:noreply,
         %{state | prerender: pr2, pending_pids: MapSet.put(drop_dead(state.pending_pids), pid)}}

      _ ->
        # Chain was discarded (off-script) while this was in flight.
        {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
    end
  end

  def handle_info(
        {:prerender_director_done, {:error, reason}, _started_at, _call_ms, _model, _sid, index,
         _seed_url, _seed_delta},
        state
      ) do
    case state.prerender do
      %{index: ^index} ->
        Logger.debug("[prerender] director error (#{inspect(reason)}); pausing deep look-ahead")
        # Only the CHAIN stops here — anything already cached in `prerendered`
        # stays valid and will still be promoted when the singer reaches it.
        {:noreply, recover_from_prerender_failure(state, index)}

      _ ->
        {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
    end
  end

  def handle_info({:prerender_image_done, _r, _t, sid, _i}, %{session_id: cur} = state)
      when sid != cur do
    {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
  end

  def handle_info(
        {:prerender_image_done, {:ok, url, frames, prompt}, timings, _sid, index},
        state
      ) do
    case state.prerender do
      %{index: ^index, status: :image} = pr ->
        out = image_out(url, frames, prompt, timings)
        ready = %{pr | status: :ready, frame_msg: out.msg, frame_url: url, frame_route: out.route}
        state = %{state | prerender: nil, pending_pids: drop_dead(state.pending_pids)}

        case state.speculation do
          # speculate_next/1 was already WAITING on exactly this line (it found
          # the chain mid-render and installed a placeholder instead of racing
          # a duplicate) — promote straight into the active slot, carrying over
          # whatever `confirmed` the placeholder had already picked up.
          %{index: ^index, status: :pending_prerender, confirmed: confirmed?} ->
            promoted = Map.put(ready, :confirmed, confirmed?)
            state = %{state | speculation: promoted}

            if confirmed? do
              Logger.info("[prerender] line #{index} ready — already confirmed, revealing")
              {:noreply, reveal_speculation(state)}
            else
              Logger.debug("[prerender] line #{index} ready, promoted to the active slot")
              {:noreply, maybe_deepen_lookahead(state)}
            end

          _ ->
            state = %{state | prerendered: Map.put(state.prerendered, index, ready)}
            Logger.debug("[prerender] line #{index} ready, cached for later reveal")
            {:noreply, maybe_deepen_lookahead(state)}
        end

      _ ->
        {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
    end
  end

  def handle_info({:prerender_image_done, {:error, reason}, timings, _sid, index}, state) do
    Logger.warning(
      "[prerender] image FAILED #{route_of(timings)} (#{inspect(reason)}); pausing deep look-ahead"
    )

    case state.prerender do
      %{index: ^index} -> {:noreply, recover_from_prerender_failure(state, index)}
      _ -> {:noreply, %{state | pending_pids: drop_dead(state.pending_pids)}}
    end
  end

  # Stop the chain and, if speculate_next/1 was waiting on exactly the line
  # that just failed (a `:pending_prerender` placeholder), un-stick it so the
  # NEXT trigger retries the ordinary way instead of waiting forever for a
  # promotion that will never come. Frames already in `prerendered` are
  # untouched — a failure further down the chain doesn't invalidate them.
  defp recover_from_prerender_failure(state, index) do
    state = %{state | prerender: nil, pending_pids: drop_dead(state.pending_pids)}

    state =
      case state.speculation do
        %{index: ^index, status: :pending_prerender} -> %{state | speculation: nil}
        _ -> state
      end

    maybe_speculate(state)
  end

  defp route_of(timings) do
    case Map.get(timings, :image_route) do
      %{provider: p, route: r, model: m, steps: s} ->
        "#{p} #{r} #{s}st #{m}"

      _ ->
        "#{Sinestesia.ImageGen.provider()} #{Sinestesia.ImageGen.render_mode()} (route not reported)"
    end
  end

  # Turn the common failures into the next thing to check, so a failing show
  # doesn't need a developer reading provider source at the sound desk.
  defp diagnosis(%Req.TransportError{reason: :timeout}, timings) do
    case Map.get(timings, :image_route) do
      %{route: "i2i"} ->
        "hint:   i2i timed out. The provider must fetch/receive the previous frame " <>
          "(#{Map.get(timings, :image_input, "?")}) before it can start rendering, " <>
          "so i2i can time out where t2i on the same provider succeeds. " <>
          "Try RENDER_MODE=t2i, or fewer steps."

      _ ->
        "hint:   the provider accepted the connection but never answered in budget."
    end
  end

  defp diagnosis(%Req.TransportError{reason: :econnrefused}, _timings),
    do: "hint:   nothing is listening — is the sidecar running?"

  defp diagnosis({:bad_status, status, _body}, _timings) when status in [401, 403],
    do: "hint:   provider rejected the credentials; check the API key for this provider."

  defp diagnosis({:bad_status, 429, _body}, _timings),
    do: "hint:   rate limited."

  defp diagnosis(reason, _timings) when reason in [:no_fal_key, :no_key],
    do: "hint:   no API key configured for this provider (see GET /config)."

  defp diagnosis(_reason, _timings), do: ""

  def handle_info({:style_curated, _result, sid}, %{session_id: cur} = state)
      when sid != cur do
    Logger.info("[curator] dropping stale result (session #{sid} ≠ #{cur})")
    {:noreply, state}
  end

  def handle_info({:style_curated, {:ok, style}, _sid}, state) do
    Logger.info("[curator] picked style: #{style}")
    apply_style(state, style, _from_curator? = true)
  end

  def handle_info({:style_curated, {:error, reason}, _sid}, state) do
    Logger.warning("[curator] failed (#{inspect(reason)}); keeping current style")
    # Don't relock — allow retry on next batch of lyrics
    {:noreply, %{state | style_locked?: false}}
  end

  def handle_info({:EXIT, pid, reason}, %{socket: socket} = state) when pid == socket do
    Logger.info("pipeline: socket exited (#{inspect(reason)}); shutting down")
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.stts, fn {_p, p_pid} -> p_pid == pid end) do
      {provider, _} ->
        Logger.warning("[#{provider}] exited (#{inspect(reason)}); attempting restart")

        new_stts =
          case start_stt(provider, state.socket) do
            {:ok, new_pid} -> Map.put(state.stts, provider, new_pid)
            _ -> Map.delete(state.stts, provider)
          end

        {:noreply, %{state | stts: new_stts}}

      nil ->
        Logger.debug("pipeline: ignored EXIT from #{inspect(pid)} (#{inspect(reason)})")
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.info("pipeline: terminating (#{inspect(reason)})")

    Enum.each(state.stts, fn {_provider, pid} ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    :ok
  end

  ## Internals

  # Story mode styling (found empirically with the replay harness — see
  # tests/README.md):
  #
  #   * FULL style note in the prompt only until a styled image lands
  #     (bootstrap / style change). Repeating the full descriptor list every
  #     frame drags the image into the style's fixed point ("geometric
  #     shapes" → flat polygons by frame 19); per-frame anchors bias content.
  #   * Recovery is a real CANVAS pass, not prompt text: every
  #     STYLE_REFRESH_EVERY images (default 4, counting ALL images) the
  #     request carries `style_pass` and the sidecar chains a gentle
  #     whole-canvas img2img with the style note after the main op. Appending
  #     style text to an element inpaint only styles the ellipse — observed
  #     live 2026-06-10: ~30 consecutive inpaints turned the canvas abstract
  #     with no recovery ever firing.
  #
  # Classic mode renders each frame from scratch; the Director styles its own
  # prompts there.
  # Turn the Director's raw reply into the image request. In compose mode
  # (default), "NEW: <element> | POS: <pos>" becomes a localized inpaint —
  # only that region is repainted, with the element as the whole prompt, so
  # the lyric's words are guaranteed pixels — and "ATMOS: ..." becomes a
  # GENTLE whole-canvas img2img pass (low strength, so it can't wash away
  # previously painted elements). COMPOSE_MODE=global keeps the old behavior.
  defp compose_image_request(raw, state) do
    if Sinestesia.Director.compose?() do
      case Sinestesia.Director.parse_story(raw) do
        %{kind: :new, element: element, placement: pos} ->
          # An inpaint paints the masked region FROM SCRATCH — the element
          # prompt is the only style signal that region will ever get, so it
          # ALWAYS carries the full style note. This is not the per-frame
          # repetition bias (vetoed for global passes): only the ellipse
          # hears it, the rest of the canvas is untouched by construction.
          # Without it elements are born colored/photoreal and the gentle
          # style_pass can't fix them after the fact (observed live
          # 2026-06-10: golden/purple dresses on a B&W woodcut canvas).
          {stamped, state} = stamp_element(element, state)

          # Bootstrap has no canvas yet — it goes to t2i with the plain
          # prompt; inpaint only applies once a previous image exists.
          if state.last_image_url do
            pos = avoid_collision(pos, state)
            state = %{state | recent_placements: Enum.take([pos | state.recent_placements], 3)}
            {style_extra, state} = maybe_style_pass(state)
            {stamped, [element: stamped, placement: pos] ++ style_extra, state}
          else
            {stamped, [], state}
          end

        %{kind: :atmos, text: text} ->
          {stamped, state} = stamp_style(text, state)
          {style_extra, state} = maybe_style_pass(state)
          {stamped, [strength: atmos_strength(), steps: 5] ++ style_extra, state}
      end
    else
      {stamped, state} = stamp_style(raw, state)
      maybe_style_refresh(stamped, state)
    end
  end

  # Style recovery every STYLE_REFRESH_EVERY images, global mode. For the
  # local sidecar it rides as `style_pass` (a real whole-canvas re-style);
  # for prompt-following providers (fal Flux etc.) the full style note goes
  # straight into the prompt TEXT — between refreshes prompts stay clean so
  # the scene words carry full weight, and img2img holds the look meanwhile.
  defp maybe_style_refresh(stamped, state) do
    refresh = style_refresh_every()
    count = state.frames_since_style + 1

    cond do
      # t2i: stamp_style already put the full style on every prompt.
      Sinestesia.ImageGen.render_mode() == :t2i ->
        {stamped, [], state}

      refresh == 0 or count < refresh ->
        {stamped, [], %{state | frames_since_style: count}}

      true ->
        # Refresh frame: full style in the prompt TEXT (global passes hear it
        # canvas-wide) and, on the local sidecar, ALSO a real whole-canvas
        # style_pass — text alone is weak under Turbo's CFG-free conditioning.
        extra =
          if Sinestesia.ImageGen.provider() == :local_sdxl,
            do: [style_pass: state.style],
            else: []

        {"#{stamped}. #{state.style}", extra, %{state | frames_since_style: 0}}
    end
  end

  defp compose_tag(extra) do
    base =
      case Keyword.get(extra, :placement) do
        nil -> if Keyword.has_key?(extra, :strength), do: " [atmos]", else: ""
        pos -> " [inpaint@#{pos}]"
      end

    if Keyword.has_key?(extra, :style_pass), do: base <> " [style-pass]", else: base
  end

  # Atmospheric passes must be subtle: at the default img2img strength (0.78)
  # they would re-synthesize most of the canvas and erase inpainted elements.
  defp atmos_strength do
    case Float.parse(System.get_env("COMPOSE_ATMOS_STRENGTH", "0.4")) do
      {s, _} when s > 0 and s <= 1 -> s
      _ -> 0.4
    end
  end

  @all_placements ~w(top-left top top-right left center right bottom-left bottom bottom-right)

  # Gemma reuses positions despite being told not to (observed: top-left 4x
  # in one song), and each reuse erases what was painted there. Redirect a
  # recently used placement to a free one.
  defp avoid_collision(pos, %{recent_placements: recent}) do
    if pos in recent do
      case Enum.reject(@all_placements, &(&1 in recent)) do
        [] -> pos
        free -> Enum.random(free)
      end
    else
      pos
    end
  end

  # Every STYLE_REFRESH_EVERY images, attach the full style note as a
  # `style_pass`: the sidecar runs a gentle whole-canvas re-style after the
  # main op (see local-sdxl STYLE_PASS_STRENGTH). 0 disables.
  defp maybe_style_pass(state) do
    refresh = style_refresh_every()
    count = state.frames_since_style + 1

    if refresh > 0 and count >= refresh do
      {[style_pass: state.style], %{state | frames_since_style: 0}}
    else
      {[], %{state | frames_since_style: count}}
    end
  end

  # Element inpaints: full style note, every time (see compose_image_request).
  # Doesn't touch frames_since_style — styling one ellipse at birth doesn't
  # recover whatever drift the rest of the canvas accumulated.
  defp stamp_element(element, state) do
    if Sinestesia.Director.mode() == :story and is_binary(state.style) and state.style != "" do
      {"#{element}. #{state.style}", state}
    else
      {element, state}
    end
  end

  defp stamp_style(prompt, state) do
    cond do
      Sinestesia.Director.mode() != :story ->
        {prompt, state}

      # T2I render: every frame is born from text alone, so every prompt
      # carries the full style — there's no feedback loop for repetition to
      # bias (the style fixed-point collapse was an img2img phenomenon).
      Sinestesia.ImageGen.render_mode() == :t2i ->
        {"A single scene showing: #{prompt}. #{state.style}", %{state | frames_since_style: 0}}

      not state.style_stamped? ->
        {"#{prompt}. #{state.style}", %{state | frames_since_style: 0}}

      true ->
        case style_anchor(state.style) do
          "" -> {prompt, state}
          anchor -> {"#{prompt}. #{anchor}", state}
        end
    end
  end

  defp style_refresh_every do
    case Integer.parse(System.get_env("STYLE_REFRESH_EVERY", "4")) do
      {n, _} when n >= 0 -> n
      _ -> 4
    end
  end

  # Per-frame style anchor: OFF by default. Repeating even a short style
  # fragment every prompt biases the sequence — an artist name ("Tarsila do
  # Amaral style") carries composition and content, not just technique, and
  # fights accumulation. Set STYLE_ANCHOR to a medium-only descriptor (e.g.
  # "flat painted illustration") to re-enable it; "first" restores the old
  # behavior (the style's first comma-clause).
  defp style_anchor(style) do
    case System.get_env("STYLE_ANCHOR") do
      nil -> ""
      "none" -> ""
      "first" -> style |> String.split(",", parts: 2) |> hd() |> String.trim()
      custom -> String.trim(custom)
    end
  end

  @curator_trigger_count 5

  defp maybe_curate_style(%{style_locked?: true} = state), do: state

  defp maybe_curate_style(%{final_lyric_count: n} = state) when n >= @curator_trigger_count do
    Logger.info("[curator] firing after #{n} final lyrics")
    pid = spawn_curator(state)
    # Optimistically lock so we don't double-fire; unlock if curator fails
    %{state | style_locked?: true, pending_pids: MapSet.put(state.pending_pids, pid)}
  end

  defp maybe_curate_style(state), do: state

  defp spawn_curator(state) do
    parent = self()
    lyrics = state.lyrics
    expressive = state.expressive
    sid = state.session_id

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:style_curated, Sinestesia.StyleCurator.curate(lyrics, expressive), sid})
      end)

    pid
  end

  defp apply_style(state, raw_style, from_curator?) do
    new_style = Sinestesia.Director.sanitize_style(raw_style)

    if new_style == state.style do
      # Same style — but if from curator, mark as locked so we don't fire again
      {:noreply, if(from_curator?, do: %{state | style_locked?: true}, else: state)}
    else
      tag = if from_curator?, do: "[curator]", else: "[style]"

      Logger.info(
        "#{tag} #{inspect(state.style)} → #{inspect(new_style)} (resetting conversation)"
      )

      push(state.socket, %{
        type: "style",
        style: new_style,
        source: if(from_curator?, do: "curator", else: "user"),
        ts: now_ms()
      })

      {:noreply,
       %{
         state
         | style: new_style,
           style_locked?: true,
           director_conversation: Sinestesia.Director.init_conversation(new_style),
           last_director_text: "",
           last_image_url: nil,
           # Re-stamp the new style onto the next image (deliberate change).
           style_stamped?: false,
           frames_since_style: 0,
           recent_placements: []
       }}
    end
  end

  defp update_text_state(state, _provider, "", _is_final, _latency), do: state

  defp update_text_state(state, provider, text, is_final, latency) do
    prev_interim = Map.get(state.last_interims, provider, "")
    prev_final = Map.get(state.last_finals, provider, "")

    same_as_before? =
      (is_final and text == prev_final) or
        (not is_final and text == prev_interim)

    cond do
      same_as_before? ->
        state

      is_final ->
        # StyleCurator is intentionally NOT invoked here. We tried auto-picking
        # the style after N lyrics, but it kept overwriting the front-end's
        # style input mid-song. Style is now driven 100% by the operator typing
        # in the front, or by the IMAGE_MODE default at session/reset.
        %{
          state
          | lyrics: state.lyrics ++ [text],
            last_interims: Map.put(state.last_interims, provider, text),
            last_finals: Map.put(state.last_finals, provider, text),
            last_text_at: Map.put(state.last_text_at, provider, now_ms()),
            last_stt_ms: latency,
            last_stt_provider: provider,
            final_lyric_count: state.final_lyric_count + 1,
            since_last_director: true
        }

      true ->
        %{
          state
          | last_interims: Map.put(state.last_interims, provider, text),
            last_text_at: Map.put(state.last_text_at, provider, now_ms()),
            last_stt_ms: latency,
            last_stt_provider: provider,
            since_last_director: true
        }
    end
  end

  def which_providers do
    case System.get_env("STT_PROVIDER", "elevenlabs") |> String.downcase() do
      "both" -> [:elevenlabs, :deepgram]
      "all" -> [:elevenlabs, :deepgram, :local_whisper]
      "deepgram" -> [:deepgram]
      "local_whisper" -> [:local_whisper]
      "local" -> [:local_whisper]
      # A/B compare ElevenLabs against local Whisper in the same session
      "eleven_local" -> [:elevenlabs, :local_whisper]
      # Replay a recorded session (REPLAY_FILE) instead of live STT — exercises
      # the full Director → image chain without anyone singing.
      "replay" -> [:replay]
      _ -> [:elevenlabs]
    end
  end

  defp start_stts(providers, socket_pid) do
    Enum.reduce(providers, %{}, fn provider, acc ->
      case start_stt(provider, socket_pid) do
        {:ok, pid} -> Map.put(acc, provider, pid)
        _ -> acc
      end
    end)
  end

  defp start_stt(:elevenlabs, socket_pid) do
    case Sinestesia.ElevenSTT.start_link(self()) do
      {:ok, pid} ->
        Logger.info("[elevenlabs] started")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[elevenlabs] disabled: #{inspect(reason)}")

        send(
          socket_pid,
          {:push_json, %{type: "error", message: "elevenlabs disabled: #{inspect(reason)}"}}
        )

        {:error, reason}
    end
  end

  defp start_stt(:deepgram, socket_pid) do
    case Sinestesia.Deepgram.start_link(self()) do
      {:ok, pid} ->
        Logger.info("[deepgram] started")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[deepgram] disabled: #{inspect(reason)}")

        send(
          socket_pid,
          {:push_json, %{type: "error", message: "deepgram disabled: #{inspect(reason)}"}}
        )

        {:error, reason}
    end
  end

  defp start_stt(:local_whisper, socket_pid) do
    case Sinestesia.LocalWhisperSTT.start_link(self()) do
      {:ok, pid} ->
        Logger.info("[local_whisper] started")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning(
          "[local_whisper] disabled: #{inspect(reason)} (is the sidecar running on :8002?)"
        )

        send(
          socket_pid,
          {:push_json, %{type: "error", message: "local_whisper disabled: #{inspect(reason)}"}}
        )

        {:error, reason}
    end
  end

  defp start_stt(:replay, socket_pid) do
    case Sinestesia.ReplaySTT.start_link(self()) do
      {:ok, pid} ->
        Logger.info("[replay] started")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[replay] disabled: #{inspect(reason)} (set REPLAY_FILE)")

        send(
          socket_pid,
          {:push_json, %{type: "error", message: "replay disabled: #{inspect(reason)}"}}
        )

        {:error, reason}
    end
  end

  defp send_audio(:elevenlabs, pid, bin), do: Sinestesia.ElevenSTT.send_audio(pid, bin)
  defp send_audio(:deepgram, pid, bin), do: Sinestesia.Deepgram.send_audio(pid, bin)
  defp send_audio(:local_whisper, pid, bin), do: Sinestesia.LocalWhisperSTT.send_audio(pid, bin)
  defp send_audio(:replay, pid, bin), do: Sinestesia.ReplaySTT.send_audio(pid, bin)

  # Only local Whisper carries song-scoped state (audio buffer + detected
  # language). The cloud providers auto-detect per utterance, so reset is a no-op.
  # Replay restarts the recorded session from the top.
  defp reset_stt(:local_whisper, pid), do: Sinestesia.LocalWhisperSTT.reset(pid)
  defp reset_stt(:replay, pid), do: Sinestesia.ReplaySTT.reset(pid)
  defp reset_stt(_provider, _pid), do: :ok

  # Bootstrap (first image): wait for a richer prompt so the opening drawing
  # has enough substance. With img2img strength 0.8 the first image dominates
  # the rest of the song, so it must NOT be drawn from 4-5 words alone.
  @bootstrap_min_words 15
  # Word window for the first Director call (vs @window_words=10 for subsequent).
  @bootstrap_window_words 30
  # Default window for subsequent calls. Defined here (NOT later) because Elixir
  # module attributes are not hoisted — used in maybe_trigger below.
  @window_words 10
  # Wider window when there are committed lines waiting: an in-progress partial
  # will keep growing and get another chance, a dropped commit will not.
  @catchup_window_words 24
  # Don't fire the Director on sub-word debris like "ul" (the tail of an
  # elongated "azuuuu...ul" split across STT segments) — it wastes a whole
  # image cycle on an atmospheric non-prompt. Real 2-word lines ("Vai voando")
  # still fire; skipped fragments aren't lost, they ride along in the next
  # window once more words arrive.
  @min_director_words 2

  defp maybe_trigger(%{generating?: true} = state), do: state
  # A look-ahead frame is in flight or held for the next line. Reactive triggers
  # are blocked so we never run two Director cycles at once; the speculation is
  # revealed (on STT confirmation) or discarded (off-script) before this unblocks.
  defp maybe_trigger(%{speculation: s} = state) when not is_nil(s), do: state
  defp maybe_trigger(%{since_last_director: false} = state), do: state

  defp maybe_trigger(state) do
    now = now_ms()
    bootstrap? = bootstrap?(state)

    cond do
      # No known script (lookahead off, or nothing pasted yet) — the only
      # signal available is a raw word count, so that's what the reactive path
      # has always used. @bootstrap_min_words is a real but ARBITRARY number
      # here: it exists only because there's nothing better to go on.
      bootstrap? and is_nil(state.bootstrap_speculation) and
          accumulated_word_count(state) < @bootstrap_min_words ->
        state

      # A script IS known, so we don't need to guess: the eager render already
      # covers a musically coherent unit (the first STANZA, or a small
      # fallback window when no real stanza breaks were given — see
      # bootstrap_content_and_target/1), and we gate reveal on having ACTUALLY
      # SUNG through that unit, whatever its natural word count turns out to
      # be for THIS song. An 8-word opening line reveals in 8 words; a longer
      # one waits longer — no fixed threshold either way.
      bootstrap? and not is_nil(state.bootstrap_speculation) and
          not bootstrap_target_reached?(state) ->
        state

      bootstrap? and match?(%{status: :ready}, state.bootstrap_speculation) ->
        # Real singing just reached the target, and the eager bootstrap is
        # already rendered — use it instead of firing a second, redundant
        # Director call for the same opening.
        reveal_bootstrap_speculation(state)

      bootstrap? and not is_nil(state.bootstrap_speculation) ->
        # Reached the target, but the eager render isn't done yet. Mark it
        # wanted and wait — its own completion handler reveals it. Must NOT
        # fall through to firing the reactive bootstrap below, or the opening
        # gets rendered twice.
        %{state | bootstrap_speculation: Map.put(state.bootstrap_speculation, :confirmed, true)}

      now - state.last_director_at < director_min_interval_ms() ->
        state

      true ->
        # Bootstrap input: ALL accumulated finals + current interim. The gate
        # already saw 15+ words cumulatively, but pick_current_line only sees
        # the latest interim — which ElevenLabs VAD resets to a few words
        # after each commit. Sending that alone gives the model 4 words and
        # it confabulates (asks for the song title, etc).
        text =
          if bootstrap? do
            bootstrap_text(state, @bootstrap_window_words)
          else
            unsent_text(state, @window_words)
          end

        cond do
          text == "" ->
            state

          not bootstrap? and word_count(text) < @min_director_words ->
            # Keep since_last_director untouched: the next interim grows the
            # window and re-triggers naturally.
            Logger.debug("[director] skip fragment: #{inspect(text)}")
            state

          text == state.last_director_text ->
            Logger.debug("[director] skip duplicate: #{inspect(text)}")
            %{state | since_last_director: false}

          true ->
            if bootstrap?,
              do:
                Logger.info(
                  "[director] bootstrap fire with #{word_count(text)} words: #{inspect(text)}"
                )

            pid = spawn_director(state, text)

            %{
              state
              | last_director_at: now,
                since_last_director: false,
                generating?: true,
                last_director_text: text,
                # Every line committed so far has now been handed over. The
                # in-progress partial deliberately does NOT advance the cursor:
                # it is still growing, and when it commits, the full line must
                # reach the Director — that is the whole point.
                lyrics_sent: length(state.lyrics),
                pending_pids: MapSet.put(state.pending_pids, pid)
            }
        end
    end
  end

  # Build the bootstrap input by joining ALL final lyrics so far + the latest
  # interim (if it isn't already a final), then taking the trailing N words.
  defp bootstrap_text(state, window) do
    finals = state.lyrics |> Enum.join(" ")

    latest_interim =
      state.last_interims
      |> Map.values()
      |> Enum.reject(&(&1 == "" or &1 in state.lyrics))
      |> Enum.max_by(&word_count/1, fn -> "" end)

    [finals, latest_interim]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> last_n_words(window)
  end

  # Bootstrap (initial rich-opening gate) only applies ONCE per session —
  # the very first Director call. We do NOT re-enter bootstrap after a style
  # change, because by then the singer is mid-song and we'd lock up waiting
  # for word counts that already exist.
  defp bootstrap?(state), do: not state.bootstrap_done?

  # Count words across ALL final lyrics so far. Counting interims is unreliable:
  # ElevenLabs in VAD mode commits and RESETS the interim after each segment,
  # so an interim alone never grows past one line. We need cumulative finals.
  defp accumulated_word_count(state) do
    finals = state.lyrics |> Enum.map(&word_count/1) |> Enum.sum()

    # Add the current interim ONLY if it's not already covered by the last final
    # (avoid double-counting when the interim equals the just-committed line).
    interim_extra =
      state.last_interims
      |> Map.values()
      |> Enum.map(fn t ->
        if t in state.lyrics, do: 0, else: word_count(t)
      end)
      |> Enum.max(fn -> 0 end)

    finals + interim_extra
  end

  defp word_count(text) when is_binary(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp word_count(_), do: 0

  defp spawn_director(state, text) do
    parent = self()
    started_at = now_ms()
    conversation = state.director_conversation
    sid = state.session_id
    # Melody/section hints appended HERE (not to last_director_text) so the
    # duplicate-line guard keeps comparing raw lyrics.
    line = text <> melody_hint(state) <> current_section_hint(state)
    Logger.debug("[director] spawning (current line: #{inspect(line)})")

    {:ok, pid} =
      Task.start(fn ->
        # Time the call HERE, inside the task. Measuring it in the parent's
        # handle_info instead would fold in however long the message sat in this
        # GenServer's mailbox behind audio frames — inflating what looks like
        # provider latency. `call_ms` is the real provider round-trip; the
        # parent derives queue wait by comparing against `started_at`.
        call_started = now_ms()
        result = Sinestesia.Director.next_prompt(conversation, line)
        call_ms = now_ms() - call_started
        # Which provider/model actually answered (the chain may have fallen
        # through) — recorded for the provenance certificate.
        send(
          parent,
          {:director_done, result, started_at, call_ms, Sinestesia.Director.last_model(), sid}
        )
      end)

    pid
  end

  # Assemble the performance record from song-scoped state and hand the finished
  # image + provenance to the mint sidecar in a Task, so chain/Walrus latency
  # never blocks the pipeline. Steps are stored newest-first; reverse to oldest.
  defp spawn_mint(state, image_url, opts) do
    parent = self()
    steps = Enum.reverse(state.performance_steps)

    transcript = state.lyrics |> Enum.join(" ")

    performance = %{
      song: opt(opts, "song", System.get_env("MINT_SONG")),
      artist: opt(opts, "artist", System.get_env("MINT_ARTIST")),
      venue: opt(opts, "venue", System.get_env("MINT_VENUE", "Live")),
      transcript: transcript,
      directorPrompts: Enum.map(steps, & &1.prompt),
      timestamps: Enum.map(steps, & &1.ts),
      # Per-prompt model attribution (the Director chain can fall back mid-song,
      # so a single song-level name would be a lie).
      directorModels: Enum.map(steps, &(&1[:model] || &1["model"])),
      # The singer's half of each exchange. Without it the certificate shows the
      # Director talking to itself; with it you can read the actual conversation
      # that produced the painting.
      directorLyrics: Enum.map(steps, &(&1[:lyric] || &1["lyric"])),
      # Every model in the chain that produced this painting — the part of the
      # certificate that says HOW it was made, not just what the prompts were.
      models: models_used(state),
      endedAtMs: now_ms()
    }

    # How the NFT image is composed from the song's frames: "webp" (default,
    # animated evolution, full colour + small), "gif" (max compatibility),
    # "collage" (contact sheet), or "final" (last frame).
    mode = opt(opts, "mode", System.get_env("MINT_COMPOSE", "webp"))
    frame_urls = state.frame_urls

    Task.start(fn ->
      performance =
        performance
        |> name_the_song()
        # Verification settles after the response, so a step's receipt can still
        # be pending when the song ends. Resolve them now: what gets hashed into
        # the NFT should be the final verdict, not a snapshot mid-flight.
        |> Map.put(:directorProofs, resolve_proofs(steps))

      # Carry the resolved title back with the receipt: the song is only named
      # inside this task, but the toast on stage wants to show what it minted.
      result =
        case do_mint(image_url, frame_urls, mode, performance) do
          {:ok, body} ->
            {:ok, Map.merge(body, %{"song" => performance.song, "artist" => performance.artist})}

          other ->
            other
        end

      send(parent, {:mint_done, result})
    end)
  end

  # One proof per Director step, aligned with the prompts: the 0G chat id and
  # whether its TEE signature verified. nil for steps that didn't run on 0G (the
  # chain falls back mid-song), which is itself worth recording honestly.
  # How long the mint will wait, in total, for still-settling 0G attestations
  # before recording them as unresolved. The song is already over and the next
  # one has started, so a few seconds costs the show nothing.
  @proof_settle_wait_ms 4_000
  @proof_poll_ms 500

  defp resolve_proofs(steps) do
    # The last call of the song is the one most likely still settling, so give
    # the chain a moment rather than minting it as "unresolved". One deadline for
    # the whole pass, not per step — otherwise a long song multiplies the wait.
    deadline = now_ms() + @proof_settle_wait_ms

    Enum.map(steps, fn step ->
      case step[:verification] || step["verification"] do
        receipt when is_map(receipt) ->
          chat_id = Map.get(receipt, "chatId") || Map.get(receipt, :chatId)
          verified = Map.get(receipt, "verified", Map.get(receipt, :verified))

          %{
            chatId: chat_id,
            provider: Map.get(receipt, "provider") || Map.get(receipt, :provider),
            model: Map.get(receipt, "model") || Map.get(receipt, :model),
            network: Map.get(receipt, "network") || Map.get(receipt, :network),
            verified:
              if(is_nil(verified), do: settled_verification(chat_id, deadline), else: verified)
          }

        _ ->
          nil
      end
    end)
  end

  # Ask the sidecar for a chat's settled verdict, retrying until `deadline`.
  # Returns nil when it still hasn't landed — recorded as "unresolved" rather
  # than guessed either way.
  defp settled_verification(chat_id, deadline) when is_binary(chat_id) and chat_id != "" do
    url =
      System.get_env("ZEROG_SIDECAR_URL", "http://127.0.0.1:8788") <>
        "/v1/verification/" <> URI.encode(chat_id)

    case Req.get(url, receive_timeout: 3_000, retry: false) do
      {:ok, %{status: 200, body: %{"pending" => false, "verified" => v}}} ->
        v

      _ ->
        if now_ms() < deadline do
          Process.sleep(@proof_poll_ms)
          settled_verification(chat_id, deadline)
        end
    end
  end

  defp settled_verification(_, _), do: nil

  # Fill in song/artist from the lyrics before minting, so the NFT isn't stamped
  # "Untitled" forever. An explicit MINT_SONG/MINT_ARTIST (or a `song`/`artist`
  # option) always wins — identification only fills the blanks, and when it
  # can't, `opening_line/1` names the performance after its own first words.
  # Runs inside the mint task, which is already off the pipeline's hot path.
  defp name_the_song(%{song: song, artist: artist} = performance)
       when is_binary(song) and song != "" and is_binary(artist) and artist != "" do
    performance
  end

  defp name_the_song(performance) do
    case Sinestesia.SongId.identify(performance.transcript) do
      {:ok, %{title: title, artist: found_artist}} ->
        %{
          performance
          | song: presence(performance.song) || title,
            artist: presence(performance.artist) || found_artist || default_artist()
        }

      {:error, reason} ->
        fallback = opening_line(performance.transcript)

        # `:unknown` is the system working — the model saw the lyrics and
        # declined to guess. Anything else means no model ever got to look, and
        # that's a config/network problem worth shouting about mid-show.
        level = if reason == :unknown, do: :info, else: :warning

        Logger.log(
          level,
          "[songid] no identification (#{inspect(reason)}); minting as #{inspect(fallback)}"
        )

        %{
          performance
          | song: presence(performance.song) || fallback,
            artist: presence(performance.artist) || default_artist()
        }
    end
  end

  # When nothing could name the song, name it after how it opens. "Numa folha
  # qualquer eu desenho…" tells you which performance this was; "Untitled" tells
  # you nothing, and the NFT keeps it forever.
  #
  # The ellipsis is load-bearing: this is an excerpt of the lyrics, not a claim
  # about the song's real title, and the record shouldn't blur the two. Falls
  # back to "Untitled" only when there is genuinely no transcript — an
  # instrumental, or a mint fired before anyone sang.
  @title_words 5
  @doc false
  def opening_line(transcript) when is_binary(transcript) do
    words =
      transcript
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    case Enum.take(words, @title_words) do
      [] ->
        "Untitled"

      taken ->
        title = taken |> Enum.join(" ") |> String.trim_trailing(",")
        if length(words) > @title_words, do: title <> "…", else: title
    end
  end

  def opening_line(_), do: "Untitled"

  # The full model chain behind the painting: speech-to-text, the Director LLM
  # (distinct per prompt, so list every one that ran), and the image model.
  defp models_used(state) do
    director =
      state.performance_steps
      |> Enum.map(&(&1[:model] || &1["model"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # From state, not the process dictionary: the route is recorded inside the
    # image task, which is a different process from this one.
    route = state.last_image_route

    %{
      stt: %{provider: state.last_stt_provider},
      director: director,
      image:
        %{provider: to_string(Sinestesia.ImageGen.provider())}
        |> Map.merge(
          case route do
            %{route: r, model: m, steps: s} -> %{route: r, model: m, steps: s}
            _ -> %{}
          end
        ),
      renderMode: to_string(Sinestesia.ImageGen.render_mode())
    }
  end

  defp default_artist, do: System.get_env("MINT_ARTIST", "Sinestesia")

  defp presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp presence(_), do: nil

  defp do_mint(image_url, frame_urls, mode, performance) do
    url = System.get_env("MINT_SIDECAR_URL", "http://127.0.0.1:8790") <> "/release"

    with {:ok, bytes} <- fetch_image_bytes(image_url),
         payload <- %{
           imageBase64: Base.encode64(bytes),
           frameUrls: frame_urls,
           mode: mode,
           performance: performance
         },
         {:ok, %{status: 200, body: body}} <-
           Req.post(url, json: payload, receive_timeout: 180_000, retry: false) do
      {:ok, body}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:bad_status, status, body}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  # The final canvas is either an https URL (fal.ai/pollinations) or an inline
  # data: URL (google) — handle both so any image provider can be minted.
  defp fetch_image_bytes("data:" <> _ = url) do
    case String.split(url, ",", parts: 2) do
      [_header, b64] ->
        case Base.decode64(b64) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, :bad_data_url}
        end

      _ ->
        {:error, :bad_data_url}
    end
  end

  defp fetch_image_bytes(url) when is_binary(url) do
    case Req.get(url, receive_timeout: 30_000, retry: false, decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:image_fetch, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp opt(opts, key, default) do
    case Map.get(opts, key) do
      v when is_binary(v) and v != "" -> v
      _ -> default
    end
  end

  defp mint_error_msg({:image_fetch, status}), do: "could not fetch the painting (#{status})"
  defp mint_error_msg({:bad_status, status, _body}), do: "mint service error (#{status})"
  defp mint_error_msg(:bad_data_url), do: "the painting image was malformed"
  defp mint_error_msg(reason), do: "mint failed: #{inspect(reason)}"

  # Compact textual summary of HOW the line is being sung (frontend `melody`
  # message, see PROTOCOL.md). Colors the Director's mood without competing
  # with the lyric content. Empty when absent or stale (>6s old — the singer
  # may have stopped).
  defp melody_hint(%{melody: m}) when map_size(m) > 0 do
    if now_ms() - Map.get(m, "ts", 0) > 6_000 do
      ""
    else
      parts =
        [
          Map.get(m, "contour"),
          register_word(Map.get(m, "register")),
          if(Map.get(m, "vibrato", 0) > 0.5, do: "vibrato"),
          energy_word(Map.get(m, "energy"))
        ]
        |> Enum.reject(&is_nil/1)

      if parts == [], do: "", else: " (melody: #{Enum.join(parts, ", ")})"
    end
  end

  defp melody_hint(_), do: ""

  # Section hint for the REACTIVE Director call: derived from `current_section`,
  # which tracks the last CONFIRMED line (updated in update_position/2). Gated on
  # MUSICAL_STRUCTURE so a user can run look-ahead without changing prompts.
  defp current_section_hint(%{current_section: nil}), do: ""

  defp current_section_hint(state) do
    if structure_enabled?() do
      state.structure.sections
      |> Enum.at(state.current_section)
      |> Sinestesia.MusicalStructure.hint()
    else
      ""
    end
  end

  # Section hint for the SPECULATIVE Director call: the target line's index is
  # known directly (it hasn't been confirmed yet, so `current_section` doesn't
  # cover it) — look it up straight from the structure.
  defp lookahead_section_hint(structure, index) do
    if structure_enabled?() do
      structure
      |> Sinestesia.MusicalStructure.section_at(index)
      |> Sinestesia.MusicalStructure.hint()
    else
      ""
    end
  end

  defp register_word(r) when is_number(r) and r >= 0.66, do: "high register"
  defp register_word(r) when is_number(r) and r <= 0.33, do: "low register"
  defp register_word(_), do: nil

  defp energy_word(e) when is_number(e) and e >= 0.66, do: "energetic"
  defp energy_word(e) when is_number(e) and e <= 0.25, do: "soft"
  defp energy_word(_), do: nil

  defp turn_count(conversation) do
    # Each user turn = one exchange. System counts as 0.
    Enum.count(conversation, &(&1.role == "user"))
  end

  @doc false
  # Everything sung since the Director last ran: the lyric lines committed while
  # it was busy, plus the line currently in progress.
  #
  # This used to be the trailing words of the current interim and nothing else,
  # which quietly threw away most of the song. ElevenLabs in VAD mode grows a
  # partial and then commits it, resetting the partial to a few words of the
  # NEXT segment. The Director fires the moment the previous frame lands, so it
  # caught whatever fragment happened to be in flight at that instant — "Num
  # instante im" — and the rest of that line ("imagino uma linda gaivota voar no
  # céu") was committed while the image was rendering and then dropped on the
  # floor, because by the next trigger the interim had moved on. Three words in,
  # a whole phrase gone, and the Director painting from a truncation.
  #
  # Committed lines are consumed exactly once (`lyrics_sent` is the cursor), so
  # nothing is sent twice and, more importantly, nothing is skipped: a line that
  # lands mid-render is still waiting at the next call.
  def unsent_text(state, window \\ @window_words) do
    unsent_finals = state.lyrics |> Enum.drop(state.lyrics_sent) |> Enum.join(" ")
    interim = latest_interim(state)

    # After a commit, `last_interims` still holds the text that just became a
    # final, and keeps holding it until the next segment starts. Appending it
    # would duplicate the line — and once the cursor had consumed that line, it
    # would keep re-offering it on every trigger forever. So the partial counts
    # only when it is genuinely still in progress: not already a committed line,
    # sent or unsent.
    in_progress? =
      interim != "" and interim not in state.lyrics and
        not String.contains?(unsent_finals, interim)

    parts = if in_progress?, do: [unsent_finals, interim], else: [unsent_finals]

    text = parts |> Enum.reject(&(&1 == "")) |> Enum.join(" ")

    # Catching up on committed lines is the case where truncation costs the most
    # — that's the material that is otherwise lost for good — so give it a wider
    # window than a bare in-progress partial.
    window = if unsent_finals == "", do: window, else: max(window, @catchup_window_words)

    last_n_words(text, window)
  end

  # The in-progress partial from whichever provider spoke most recently. Robust
  # to both segmenting providers (Deepgram → short fragments) and accumulating
  # ones (ElevenLabs → a growing line).
  defp latest_interim(state) do
    state.last_text_at
    |> Enum.map(fn {provider, ts} -> {ts, Map.get(state.last_interims, provider, "")} end)
    |> Enum.reject(fn {_, text} -> String.trim(text) == "" end)
    |> case do
      [] -> ""
      candidates -> candidates |> Enum.max_by(fn {ts, _} -> ts end) |> elem(1) |> String.trim()
    end
  end

  defp last_n_words(text, n) when is_binary(text) do
    text
    |> String.trim()
    |> String.trim_leading(".")
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(-n)
    |> Enum.join(" ")
    |> String.trim_trailing(".")
    |> String.trim_trailing(",")
    |> String.trim_trailing("-")
  end

  defp last_n_words(_, _), do: ""

  defp first_n_words(text, n) when is_binary(text) do
    text
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(n)
    |> Enum.join(" ")
  end

  defp first_n_words(_, _), do: ""

  defp spawn_image(prompt, timings, prev_url, sid, camera, extra) do
    do_spawn_image(prompt, timings, prev_url, camera, extra, fn result, t ->
      {:image_done, result, t, sid}
    end)
  end

  # Speculative sibling of spawn_image/6: same render, but the reply is tagged
  # {:spec_image_done, …, index} so the parent holds it instead of pushing it.
  defp spawn_spec_image(prompt, timings, prev_url, sid, camera, extra, index) do
    do_spawn_image(prompt, timings, prev_url, camera, extra, fn result, t ->
      {:spec_image_done, result, t, sid, index}
    end)
  end

  # The shared image-render task. `make_msg.(result, timings)` builds the reply
  # so the reactive and speculative paths differ only in how the frame comes back.
  defp do_spawn_image(prompt, timings, prev_url, camera, extra, make_msg) do
    parent = self()
    timings = Map.put(timings, :image_started_at, now_ms())

    opts = if is_binary(prev_url) and prev_url != "", do: [image_url: prev_url], else: []
    opts = if camera == neutral_camera(), do: opts, else: Keyword.put(opts, :camera, camera)
    opts = Keyword.merge(opts, extra)

    {:ok, pid} =
      Task.start(fn ->
        # Timed inside the task for the same reason as the Director call: the
        # parent's mailbox wait is our backpressure, not the provider's latency.
        call_started = now_ms()

        result =
          case Sinestesia.ImageGen.generate(prompt, opts) do
            # local_sdxl returns the latent-morph frame sequence alongside the
            # final URL; the other providers don't (normalize to []).
            {:ok, url, frames} -> {:ok, url, frames, prompt}
            {:ok, url} -> {:ok, url, [], prompt}
            err -> err
          end

        # ImageGen stashes the local-morph duration in this task's process
        # dictionary (same process), so we can split provider vs. local cost.
        morph_ms = Process.get(:morph_ms, 0)

        timings =
          timings
          |> Map.put(:image_call_ms, now_ms() - call_started)
          |> Map.put(:morph_ms, morph_ms)
          # Which model actually rendered this frame (routes differ wildly in
          # cost). Recorded by the provider before it calls out, so it is
          # present on failures too — that's the whole point.
          |> Map.put(:image_route, Sinestesia.ImageGen.last_route())
          # What we handed the provider. An i2i call that fails while a t2i call
          # on the same provider succeeds usually fails *because of* this input.
          |> Map.put(:image_input, describe_input(opts[:image_url]))
          |> Map.put(:prompt_chars, String.length(prompt))

        send(parent, make_msg.(result, timings))
      end)

    pid
  end

  # i2i hands the provider the previous frame. Whether that was an https URL the
  # provider has to fetch, or a multi-megabyte data: URL inlined in the request
  # body, changes what a failure means — and a data: URL is a common cause of a
  # call that "just times out" with no server-side error to report.
  defp describe_input(nil), do: "none (t2i)"
  defp describe_input(""), do: "none (t2i)"

  defp describe_input("data:" <> _ = url),
    do: "data: URL, #{div(byte_size(url), 1024)}KB inlined"

  defp describe_input(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) -> "url #{h}"
      _ -> "url (unparseable)"
    end
  end

  defp describe_input(other), do: inspect(other)

  # Ask the 0G sidecar for the settled verification of a receipt that went out as
  # pending, and push the resolved state to the front. Runs in its own task and
  # polls a few times: settlement is an on-chain round-trip (~1s on testnet) that
  # we deliberately do NOT wait for in the response path.
  defp resolve_verification(nil, _socket), do: :ok

  defp resolve_verification(receipt, socket) do
    chat_id = Map.get(receipt, "chatId") || Map.get(receipt, :chatId)

    # Only chase receipts still unresolved; a receipt that already carries a
    # true/false verdict is final.
    verified = Map.get(receipt, "verified", Map.get(receipt, :verified))

    if is_binary(chat_id) and chat_id != "" and is_nil(verified) do
      Task.start(fn -> poll_verification(receipt, chat_id, socket, 6) end)
    end

    :ok
  end

  defp poll_verification(_receipt, _chat_id, _socket, 0), do: :ok

  defp poll_verification(receipt, chat_id, socket, attempts) do
    Process.sleep(750)

    url =
      System.get_env("ZEROG_SIDECAR_URL", "http://127.0.0.1:8788") <>
        "/v1/verification/" <> URI.encode(chat_id)

    case Req.get(url, receive_timeout: 2_000, retry: false) do
      {:ok, %{status: 200, body: %{"pending" => false, "verified" => v}}} ->
        resolved = Map.merge(receipt, %{"verified" => v, "chatId" => chat_id})
        Sinestesia.Verifiability.put(resolved)
        send(socket, {:push_json, %{type: "verification", verification: resolved}})
        Logger.info("[0g] verification resolved for #{chat_id}: #{inspect(v)}")
        :ok

      _ ->
        poll_verification(receipt, chat_id, socket, attempts - 1)
    end
  end

  # ── Predictive look-ahead helpers ──────────────────────────────────────────

  # Shared by the operator's `lyrics` WS message and a replay session's
  # `lyrics`/`lyrics_text`: normalize into the flat script the follower matches
  # against, analyze structure from the SAME raw payload (so blank-line stanza
  # boundaries survive when present), and reset position + any look-ahead — a
  # reload mid-song is a new performance to track from scratch.
  defp load_lyrics(state, raw, log_tag) do
    script = Sinestesia.PerformanceFollower.normalize(raw)
    structure = Sinestesia.MusicalStructure.analyze(raw)
    active? = script != []

    Logger.info(
      if active? do
        "#{log_tag} loaded #{length(script)} line(s), #{length(structure.sections)} section(s)"
      else
        "#{log_tag} cleared"
      end
    )

    state
    |> discard_speculation()
    |> discard_bootstrap_speculation()
    |> Map.merge(%{
      script: script,
      script_active?: active?,
      script_cursor: -1,
      structure: structure,
      current_section: nil
    })
    |> maybe_speculate_bootstrap()
  end

  # After a completed song: move to the next setlist entry if one is active,
  # otherwise just re-arm the eager bootstrap for whatever lyrics are already
  # loaded (a single loaded song, or none).
  defp advance_setlist_or_rearm(state) do
    if state.setlist == [] do
      maybe_speculate_bootstrap(state)
    else
      load_setlist_song(state, state.setlist_index + 1)
    end
  end

  # Load the setlist entry at `index`. Skips (with a log line, never a crash)
  # any id that no longer resolves in the library — the show must go on. Past
  # the end of the setlist, leaves whatever lyrics/canvas state as-is rather
  # than clearing them out from under an operator who's still using the app.
  defp load_setlist_song(state, index) do
    case Enum.at(state.setlist, index) do
      nil ->
        Logger.info("[setlist] no song at ##{index + 1} — setlist finished")
        %{state | setlist_index: index}

      id ->
        case Sinestesia.SongLibrary.get(id) do
          nil ->
            Logger.warning("[setlist] song #{inspect(id)} not found in the library, skipping")
            load_setlist_song(state, index + 1)

          song ->
            Logger.info(
              "[setlist] loading ##{index + 1}/#{length(state.setlist)}: #{song.title}#{artist_suffix(song.artist)}"
            )

            {:noreply, state} =
              if song.style, do: apply_style(state, song.style, false), else: {:noreply, state}

            state =
              state
              |> load_lyrics(song.lyrics_text, "[setlist] #{song.title}")
              |> Map.put(:current_song_id, song.id)
              |> Map.put(:setlist_index, index)

            push(state.socket, %{
              type: "song_loaded",
              id: song.id,
              title: song.title,
              artist: song.artist,
              setlist_index: index
            })

            state
        end
    end
  end

  # When no lyrics/setlist are loaded, try to recognize the song from just a
  # few sung words — matched against every song's OPENING line in
  # Sinestesia.SongLibrary — and load it mid-stream (same eager-bootstrap
  # machinery as loading it by hand; catch_up_position_from_accumulated/1,
  # triggered from the reveal path, positions the cursor from whatever's
  # already been sung). A wrong guess is not worse than not guessing — it just
  # costs a discarded speculative render once the singer's real words diverge,
  # the same graceful fallback the rest of the look-ahead machinery relies on.
  #
  # This is the COLD-START case only (no script active yet). A script already
  # being active does NOT block re-identification for the rest of the show —
  # see `match_and_advance/2`'s `:no_match` clause, which re-runs identify/2
  # against the just-sung off-script line so a live switch to a DIFFERENT
  # catalog song (an unplanned song, or the wrong one loaded) is caught too,
  # not just the very first line of the performance.
  defp maybe_auto_identify(%{script_active?: true} = state, _is_final), do: state
  defp maybe_auto_identify(state, false), do: state

  # Only the OPENING is a distinctive signal for cross-song identification —
  # capped, not the full running transcript. match_score's overlap coefficient
  # is denominator-capped at the (short) candidate opening line, so its
  # numerator can only ever grow as more is sung; an uncapped sung_so_far would
  # make a false match strictly MORE likely the longer an unrecognized song
  # plays, with no way to self-correct. Capping to the first
  # @song_identify_max_words freezes the comparison at the actual opening,
  # matching the original "identify from the first few words" intent.
  @song_identify_max_words 24

  defp maybe_auto_identify(state, true) do
    if auto_identify_enabled?() do
      case state.lyrics |> Enum.join(" ") |> first_n_words(@song_identify_max_words) do
        "" ->
          state

        sung_so_far ->
          case Sinestesia.SongLibrary.identify(sung_so_far) do
            {:match, song} -> load_identified_song(state, song, "auto-identified")
            :no_match -> state
          end
      end
    else
      state
    end
  end

  # Shared by the cold-start path above and the mid-show re-identify in
  # match_and_advance/2's :no_match clause — both end up loading a catalog
  # song the same way a manual load_song/load_setlist_song would. Style MUST
  # be applied before load_lyrics: apply_style/3 resets director_conversation,
  # and load_lyrics's maybe_speculate_bootstrap/1 immediately spawns a
  # Director call against whatever conversation exists at that moment (see
  # gotcha #30 in HANDOFF.md — the same ordering bug this function exists to
  # not repeat for the identify path too).
  defp load_identified_song(state, song, reason) do
    Logger.info("[song-library] #{reason}: #{song.title}#{artist_suffix(song.artist)}")

    {:noreply, state} =
      if song.style, do: apply_style(state, song.style, false), else: {:noreply, state}

    push(state.socket, %{
      type: "song_identified",
      id: song.id,
      title: song.title,
      artist: song.artist
    })

    state
    |> load_lyrics(song.lyrics_text, "[song-library]")
    |> Map.put(:current_song_id, song.id)
  end

  # Re-identify against just the ONE just-confirmed off-script line, mirroring
  # the cold-start signal ("a few sung words" is enough — see identify/2's
  # docs) rather than the accumulated-and-capped text maybe_auto_identify uses
  # for its own from-scratch, no-script-yet case. Returns :no_match (never
  # switches) when auto-identify is off, nothing matches, or the match IS the
  # song already loaded — the last guard avoids a pointless reload loop from a
  # coincidental strong match against the very song already playing.
  defp mid_song_reidentify(%{current_song_id: current}, text) do
    if auto_identify_enabled?() do
      case Sinestesia.SongLibrary.identify(text) do
        {:match, %{id: ^current}} -> :no_match
        other -> other
      end
    else
      :no_match
    end
  end

  defp auto_identify_enabled?,
    do: System.get_env("SONG_AUTO_IDENTIFY") in ["1", "true", "on", "yes"]

  defp artist_suffix(nil), do: ""
  defp artist_suffix(artist), do: " (#{artist})"

  defp lookahead_enabled?,
    do: System.get_env("SPECULATIVE_LOOKAHEAD") in ["1", "true", "on", "yes"]

  defp structure_enabled?, do: System.get_env("MUSICAL_STRUCTURE") in ["1", "true", "on", "yes"]

  defp lookahead_depth do
    case Integer.parse(System.get_env("LOOKAHEAD_DEPTH", "1")) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp lyric_window do
    case Integer.parse(System.get_env("LYRIC_WINDOW", "3")) do
      {n, _} when n >= 1 -> n
      _ -> 3
    end
  end

  defp lyric_threshold do
    case Float.parse(System.get_env("LYRIC_MATCH_THRESHOLD", "0.6")) do
      {t, _} when t > 0 and t <= 1 -> t
      _ -> 0.6
    end
  end

  # Advance the script cursor from a confirmed sung line, and decide whether the
  # look-ahead path serviced this line (`:handled`) or the reactive Director
  # still needs to run (`:fallthrough`). Only finals carry a confirmed line.
  #
  # Position/section tracking and look-ahead are independent capabilities:
  # SPECULATIVE_LOOKAHEAD gets full tracking as a side effect of doing its job;
  # MUSICAL_STRUCTURE alone (no look-ahead) still tracks position so section
  # hints reach the reactive Director. Neither flag set → fully inert, same as
  # Phase 1's original behaviour.
  defp advance_script(state, _text, false), do: {state, :fallthrough}

  defp advance_script(%{script_active?: true} = state, text, true) do
    cond do
      lookahead_enabled?() -> match_and_advance(state, text)
      structure_enabled?() -> {track_position(state, text), :fallthrough}
      true -> {state, :fallthrough}
    end
  end

  defp advance_script(state, _text, true), do: {state, :fallthrough}

  # Structure-only tracking (MUSICAL_STRUCTURE without SPECULATIVE_LOOKAHEAD):
  # update the position when the follower finds forward progress; never touches
  # `speculation` (there isn't one) and never blocks the reactive Director.
  defp track_position(state, text) do
    case follower_match(state, text) do
      {:match, idx} when idx > state.script_cursor -> update_position(state, idx)
      _ -> state
    end
  end

  defp match_and_advance(state, text) do
    case follower_match(state, text) do
      {:match, idx} when idx > state.script_cursor ->
        state = update_position(state, idx)

        case state.speculation do
          # We rendered this exact line ahead of time and it's ready — reveal now.
          %{index: ^idx, status: :ready} ->
            {reveal_speculation(state), :handled}

          # Rendered but still in flight — confirm it; spec_image_done reveals it.
          %{index: ^idx} = spec ->
            {%{state | speculation: %{spec | confirmed: true}}, :handled}

          # We predicted a different line (singer jumped): drop it and let the
          # reactive Director draw the line she actually sang.
          %{} ->
            {discard_speculation(state), :fallthrough}

          nil ->
            {state, :fallthrough}
        end

      # Matched the current or an earlier line (a repeat, or STT re-segmenting the
      # same line): already on screen, nothing new to draw. Position/section are
      # left untouched — only forward progress moves them.
      {:match, _idx} ->
        {%{state | since_last_director: false}, :handled}

      # Off-script (improv, a line the pasted lyrics don't contain, or a
      # DIFFERENT song entirely): first check whether SONG_AUTO_IDENTIFY
      # recognizes this off-script line as the opening of some OTHER catalog
      # song — a live switch (wrong song loaded, or an unplanned song) — and
      # if so, load it and let its own eager bootstrap take over. Otherwise,
      # drop any look-ahead and fall back to reactive rendering from what she
      # actually sang.
      #
      # The look-ahead discard MUST also drop a still-held eager bootstrap,
      # not just ordinary speculation. Without this, `maybe_trigger`'s
      # bootstrap branch has no escape hatch: as long as `bootstrap_speculation`
      # is non-nil, it blocks on `bootstrap_target_reached?` alone (its OWN
      # from-scratch furthest_match over `state.lyrics`, oblivious to what this
      # function just found), and NOTHING is ever generated — no reveal
      # (correct, wrong content) but also no reactive fallback (wrong) — if the
      # loaded song's opening is never actually sung (wrong song loaded, or a
      # performance that diverges before the bootstrap's target line). Found
      # live: an operator loaded one song but sang a different one, and the
      # pipeline sat silent indefinitely, no matter how many real words were
      # spoken.
      :no_match ->
        case mid_song_reidentify(state, text) do
          {:match, song} ->
            {load_identified_song(state, song, "auto-identified mid-performance"), :handled}

          :no_match ->
            {state |> discard_speculation() |> discard_bootstrap_speculation(), :fallthrough}
        end
    end
  end

  defp follower_match(state, text) do
    Sinestesia.PerformanceFollower.match(text, state.script, state.script_cursor,
      window: lyric_window(),
      threshold: lyric_threshold()
    )
  end

  # Move the confirmed-position cursor forward and recompute the section it
  # falls in, logging when that crosses a section boundary (the moment a
  # section hint starts reaching the Director — see section_hint_for/1).
  defp update_position(state, idx) do
    section_id = Sinestesia.MusicalStructure.section_index_at(state.structure, idx)

    crossed? =
      structure_enabled?() and
        Sinestesia.MusicalStructure.boundary?(state.structure, state.script_cursor, idx)

    # boundary?/3 only returns true when the new section id is non-nil (see its
    # definition), so this Enum.at is always in range when crossed? is true.
    if crossed? do
      section = Enum.at(state.structure.sections, section_id)

      Logger.info(
        "[structure] entering #{section.label} (occurrence #{section.occurrence}) at line #{idx}"
      )

      tempo = Sinestesia.Tempo.display(%{bpm: state.tempo_bpm, at: state.tempo_at})
      push(state.socket, structure_msg(section, idx, tempo))
    end

    %{state | script_cursor: idx, current_section: section_id}
  end

  # The `structure` push (see PROTOCOL.md): informational only, never feeds
  # provenance. `tempo_bpm` may be nil (no confident audio estimate yet).
  defp structure_msg(section, line_index, tempo_bpm) do
    %{
      type: "structure",
      section: %{
        label: to_string(section.label),
        occurrence: section.occurrence,
        index: line_index
      },
      tempo_bpm: tempo_bpm,
      ts: now_ms()
    }
  end

  # ── Eager bootstrap: pre-render the opening from the pasted lyrics ─────────
  # Ordinarily the FIRST frame is always reactive — @bootstrap_min_words of
  # REAL singing has to accumulate before it fires (see maybe_trigger), because
  # generating it from too little content lets a poor opening dominate the
  # whole song via i2i. That word count is a real but ARBITRARY number: with
  # the whole song already pasted, we don't need to guess how much is "enough"
  # — the first STANZA already tells us. This renders the opening from that
  # coherent unit (t2i, no seed — same shape as the reactive bootstrap) the
  # moment lyrics load, and holds it exactly like an ordinary speculation:
  # revealed only once REAL singing independently reaches the SAME unit's end
  # (see bootstrap_target_reached?/1), whatever that turns out to cost in
  # words for this particular song. Runs once per song; `bootstrap_done?` (set
  # on reveal) prevents re-entry, same invariant the reactive path relies on.
  defp maybe_speculate_bootstrap(state) do
    cond do
      not lookahead_enabled?() ->
        state

      not state.script_active? ->
        state

      state.bootstrap_done? ->
        state

      not is_nil(state.bootstrap_speculation) ->
        state

      state.generating? ->
        state

      true ->
        {text, target_index} = bootstrap_content_and_target(state)

        if text == "" do
          state
        else
          gen = state.bootstrap_generation + 1
          pid = spawn_bootstrap_director(state, text, gen)

          Logger.debug(
            "[bootstrap-spec] pre-rendering the opening from pasted lyrics (through line #{target_index}): #{inspect(text)}"
          )

          bspec = %{
            status: :director,
            confirmed: false,
            pid: pid,
            new_conv: nil,
            step: nil,
            state_delta: nil,
            frame_msg: nil,
            frame_url: nil,
            frame_route: nil,
            receipt: nil,
            text: text,
            target_index: target_index
          }

          %{
            state
            | bootstrap_speculation: bspec,
              bootstrap_generation: gen,
              pending_pids: MapSet.put(state.pending_pids, pid)
          }
        end
    end
  end

  # A generous window for furthest_match/4 calls below: the accumulated-so-far
  # catch-up may span several lines by the time the opening reveals — unlike
  # the ordinary per-line follower window (tuned for one line at a time).
  @bootstrap_catchup_window 12

  # The eager bootstrap's content AND the line it needs real singing to reach
  # before revealing: the song's own FIRST LINE, always — never a whole
  # stanza, never a word-count floor.
  #
  # This replaces two earlier, progressively-less-wrong attempts (see gotchas
  # #29 and #36 in HANDOFF.md) that both still hard-coded SOME threshold
  # (first a fixed word count, then a fixed word count capped per real
  # stanza) — found live (2026-07-31) to still be waiting on the wrong unit:
  # a "stanza" is a formatting artifact of wherever the lyrics came from
  # (Aquarela's real first verse is 8 short lines with no internal blank-line
  # break), not the coherent unit the eager render actually needs. The
  # smallest thing that is ALWAYS a real, complete, pasted lyric fragment —
  # regardless of source formatting, regardless of how many words it happens
  # to contain for this particular song — is a single line. No fixed
  # parameter survives contact with "every song is a different reality"; the
  # first line is the one unit that needs no parameter at all to identify.
  #
  # A genuinely richer, per-song judgment of "is one line actually enough, or
  # does the opening phrase need two" is a real, separate improvement (an
  # LLM read of the whole lyrics, off the critical path, with a hard fallback
  # to this exact behavior) — proposed, not built here; see HANDOFF #37.
  defp bootstrap_content_and_target(state) do
    case state.script do
      [first | _] -> {first, 0}
      [] -> {"", 0}
    end
  end

  # Has real (confirmed) singing reached the eager bootstrap's target line yet?
  # Uses furthest_match/4 (not match/4) for the same reason
  # catch_up_position_from_accumulated/1 does — everything sung SO FAR may
  # already cover several lines, and we want the FURTHEST one reached, not the
  # nearest.
  defp bootstrap_target_reached?(%{bootstrap_speculation: %{target_index: target}} = state) do
    sung_so_far = state.lyrics |> Enum.join(" ")

    case Sinestesia.PerformanceFollower.furthest_match(sung_so_far, state.script, -1,
           window: max(target + 1, @bootstrap_catchup_window),
           threshold: lyric_threshold()
         ) do
      {:match, idx} -> idx >= target
      :no_match -> false
    end
  end

  defp spawn_bootstrap_director(state, text, gen) do
    parent = self()
    started_at = now_ms()
    conversation = state.director_conversation
    sid = state.session_id
    line = text <> melody_hint(state)

    {:ok, pid} =
      Task.start(fn ->
        call_started = now_ms()
        result = Sinestesia.Director.next_prompt(conversation, line)
        call_ms = now_ms() - call_started

        send(
          parent,
          {:bootstrap_spec_director_done, result, started_at, call_ms,
           Sinestesia.Director.last_model(), sid, gen}
        )
      end)

    pid
  end

  # No seed URL — same t2i shape as the reactive bootstrap (there is no
  # previous frame yet).
  defp spawn_bootstrap_image(prompt, timings, sid, gen, camera, extra) do
    do_spawn_image(prompt, timings, nil, camera, extra, fn result, t ->
      {:bootstrap_spec_image_done, result, t, sid, gen}
    end)
  end

  # Adopt the held eager-bootstrap frame exactly like the reactive bootstrap
  # completing would: mark bootstrap_done?, set the canvas, adopt the
  # conversation and provenance step. Then, since this render was built from
  # the SCRIPT rather than confirmed STT, catch the cursor up to wherever real
  # singing has actually gotten (furthest_match/4 — see PerformanceFollower)
  # before letting ordinary per-line look-ahead continue.
  defp reveal_bootstrap_speculation(%{bootstrap_speculation: bs} = state) do
    push(state.socket, bs.frame_msg)
    resolve_verification(bs.receipt, state.socket)
    Logger.info("[bootstrap-spec] revealed the opening frame, pre-rendered from pasted lyrics")

    delta = bs.state_delta || %{}

    state = %{
      state
      | bootstrap_speculation: nil,
        generating?: false,
        last_image_url: bs.frame_url,
        last_image_route: bs.frame_route || state.last_image_route,
        frame_urls: state.frame_urls ++ [bs.frame_url],
        director_conversation: bs.new_conv || state.director_conversation,
        performance_steps: [bs.step | state.performance_steps],
        style_stamped?: true,
        bootstrap_done?: true,
        recent_placements: Map.get(delta, :recent_placements, state.recent_placements),
        frames_since_style: Map.get(delta, :frames_since_style, state.frames_since_style),
        since_last_director: false,
        pending_pids: drop_dead(state.pending_pids)
    }

    state
    |> catch_up_position_from_accumulated()
    |> maybe_speculate()
  end

  defp catch_up_position_from_accumulated(state) do
    sung_so_far = state.lyrics |> Enum.join(" ")

    case Sinestesia.PerformanceFollower.furthest_match(
           sung_so_far,
           state.script,
           state.script_cursor,
           window: @bootstrap_catchup_window,
           threshold: lyric_threshold()
         ) do
      {:match, idx} when idx > state.script_cursor -> update_position(state, idx)
      _ -> state
    end
  end

  # If lyrics are loaded and the canvas is ready, render the predicted next line
  # ahead of the singer. At most one look-ahead cycle exists at a time (the
  # speculation slot), which also keeps a single Director call in flight.
  defp maybe_speculate(state) do
    cond do
      not lookahead_enabled?() -> state
      not state.script_active? -> state
      # The opening frame is USUALLY reactive (see maybe_trigger's bootstrap
      # branch) unless the eager bootstrap above already revealed one.
      not state.bootstrap_done? -> state
      not is_binary(state.last_image_url) -> state
      state.generating? -> state
      not is_nil(state.speculation) -> state
      true -> speculate_next(state)
    end
  end

  defp speculate_next(state) do
    next = state.script_cursor + 1

    cond do
      # LOOKAHEAD_DEPTH > 1 already FINISHED rendering this line in the
      # background — promote it straight to the active slot, no render needed.
      Map.has_key?(state.prerendered, next) ->
        {cached, rest} = Map.pop(state.prerendered, next)
        Logger.debug("[spec] promoting pre-rendered line #{next} from the deep-lookahead cache")
        maybe_deepen_lookahead(%{state | speculation: cached, prerendered: rest})

      # The deep-lookahead chain is ALREADY rendering exactly this line, just
      # not finished yet. Don't spawn a competing duplicate render — install a
      # placeholder so match_and_advance/2 knows "in flight elsewhere, wait for
      # it" (identical to how it already waits on an ordinary in-flight
      # speculation). See prerender_image_done's success clause for the promotion.
      match?(%{index: ^next}, state.prerender) ->
        Logger.debug(
          "[spec] line #{next} already rendering via the deep-lookahead chain; waiting"
        )

        placeholder = pending_prerender_placeholder(next, state.prerender.line)
        %{state | speculation: placeholder}

      true ->
        case Enum.at(state.script, next) do
          line when is_binary(line) and line != "" ->
            pid = spawn_spec_director(state, line, next)
            Logger.debug("[spec] look-ahead render for line #{next}: #{inspect(line)}")

            spec = %{
              index: next,
              line: line,
              status: :director,
              confirmed: false,
              pid: pid,
              new_conv: nil,
              step: nil,
              state_delta: nil,
              frame_msg: nil,
              frame_url: nil,
              frame_route: nil,
              receipt: nil
            }

            state = %{
              state
              | speculation: spec,
                pending_pids: MapSet.put(state.pending_pids, pid)
            }

            maybe_deepen_lookahead(state)

          _ ->
            # End of the pasted lyrics — nothing left to look ahead to.
            state
        end
    end
  end

  # A "wait for it" marker in the speculation slot: no pid of its own (the deep
  # look-ahead chain owns the real render), so match_and_advance/2's ordinary
  # `%{index: ^idx} = spec -> mark confirmed` clause needs no special case, and
  # discard_speculation/1's `is_pid(pid)` guard is a safe no-op if this ever
  # needs discarding directly (in practice prerender_director/image_done's
  # error clauses handle that — see the comment there).
  defp pending_prerender_placeholder(index, line) do
    %{
      index: index,
      line: line,
      status: :pending_prerender,
      confirmed: false,
      pid: nil,
      new_conv: nil,
      step: nil,
      state_delta: nil,
      frame_msg: nil,
      frame_url: nil,
      frame_route: nil,
      receipt: nil
    }
  end

  # Try to push the background prerender chain one line deeper, if
  # LOOKAHEAD_DEPTH allows it and there's a known frontier to seed from. A
  # no-op at the default depth of 1 — this function is never reached with
  # anything left to do, since `lookahead_extent/1` (1, for the active
  # speculation slot alone) already meets a depth of 1.
  defp maybe_deepen_lookahead(state) do
    cond do
      lookahead_depth() <= 1 ->
        state

      not lookahead_enabled?() ->
        state

      not state.script_active? ->
        state

      not is_nil(state.prerender) ->
        state

      lookahead_extent(state) >= lookahead_depth() ->
        state

      true ->
        case lookahead_frontier(state) do
          # Nothing ready yet to seed the next render from — the active
          # speculation (or the last prerender) hasn't produced an image yet.
          # Whichever finishes will call this again.
          nil ->
            state

          {frontier_index, frontier_url, frontier_conv, frontier_delta} ->
            start_prerender(
              state,
              frontier_index + 1,
              frontier_url,
              frontier_conv,
              frontier_delta
            )
        end
    end
  end

  # How many lines beyond the confirmed cursor are already spoken for: the
  # active speculation slot (any status), a prerender in flight, and whatever
  # is already cached. LOOKAHEAD_DEPTH is a ceiling on this total, not a target
  # to force — the chain only advances opportunistically as renders finish.
  defp lookahead_extent(state) do
    if(state.speculation, do: 1, else: 0) +
      if(state.prerender, do: 1, else: 0) +
      map_size(state.prerendered)
  end

  # The furthest point the pipeline has a FINISHED image for — the seed the
  # next prerender must chain from (i2i needs the actual previous frame, and
  # the conversation/placement bookkeeping that produced it). Prefers the
  # deepest cached prerender; falls back to the active speculation only once
  # IT has an image (status :ready) — before that there's nothing to seed from.
  defp lookahead_frontier(state) do
    case state.prerendered |> Map.keys() |> Enum.max(fn -> nil end) do
      idx when is_integer(idx) ->
        f = state.prerendered[idx]
        {f.index, f.frame_url, f.new_conv, f.state_delta}

      nil ->
        case state.speculation do
          %{status: :ready} = s -> {s.index, s.frame_url, s.new_conv, s.state_delta}
          _ -> nil
        end
    end
  end

  defp start_prerender(state, index, seed_url, seed_conv, seed_delta) do
    case Enum.at(state.script, index) do
      line when is_binary(line) and line != "" ->
        pid = spawn_prerender_director(state, line, index, seed_conv, seed_url, seed_delta)
        Logger.debug("[prerender] deep look-ahead render for line #{index}: #{inspect(line)}")

        pr = %{
          index: index,
          line: line,
          status: :director,
          pid: pid,
          new_conv: nil,
          step: nil,
          state_delta: nil,
          frame_msg: nil,
          frame_url: nil,
          frame_route: nil,
          receipt: nil
        }

        %{state | prerender: pr, pending_pids: MapSet.put(state.pending_pids, pid)}

      _ ->
        # End of the pasted lyrics — nothing deeper to prerender.
        state
    end
  end

  # Mirrors spawn_spec_director/3, but takes the seed conversation/URL/delta
  # EXPLICITLY rather than reading them off `state` — `state.director_conversation`
  # and `state.last_image_url` only reflect the CONFIRMED position, which is
  # behind wherever this chain's frontier has already reached.
  defp spawn_prerender_director(state, line, index, conversation, seed_url, seed_delta) do
    parent = self()
    started_at = now_ms()
    sid = state.session_id
    full = line <> melody_hint(state) <> lookahead_section_hint(state.structure, index)

    Logger.debug(
      "[prerender] director spawning for line #{index} (current line: #{inspect(full)})"
    )

    {:ok, pid} =
      Task.start(fn ->
        call_started = now_ms()
        result = Sinestesia.Director.next_prompt(conversation, full)
        call_ms = now_ms() - call_started

        send(
          parent,
          {:prerender_director_done, result, started_at, call_ms,
           Sinestesia.Director.last_model(), sid, index, seed_url, seed_delta}
        )
      end)

    pid
  end

  defp spawn_prerender_image(prompt, timings, prev_url, sid, camera, extra, index) do
    do_spawn_image(prompt, timings, prev_url, camera, extra, fn result, t ->
      {:prerender_image_done, result, t, sid, index}
    end)
  end

  defp spawn_spec_director(state, line, index) do
    parent = self()
    started_at = now_ms()
    conversation = state.director_conversation
    sid = state.session_id
    full = line <> melody_hint(state) <> lookahead_section_hint(state.structure, index)
    Logger.debug("[spec] director spawning for line #{index} (current line: #{inspect(full)})")

    {:ok, pid} =
      Task.start(fn ->
        call_started = now_ms()
        result = Sinestesia.Director.next_prompt(conversation, full)
        call_ms = now_ms() - call_started

        send(
          parent,
          {:spec_director_done, result, started_at, call_ms, Sinestesia.Director.last_model(),
           sid, index}
        )
      end)

    pid
  end

  # Reveal a held look-ahead frame and ADOPT its consequences: the same state
  # transitions the reactive :image_done path makes, plus the Director
  # conversation and placement/style bookkeeping the speculation computed but
  # deferred until now. Then look ahead to the next line.
  defp reveal_speculation(%{speculation: spec} = state) do
    push(state.socket, spec.frame_msg)
    resolve_verification(spec.receipt, state.socket)
    Logger.info("[spec] revealed line #{spec.index} on confirmation")

    delta = spec.state_delta || %{}

    state = %{
      state
      | speculation: nil,
        generating?: false,
        last_image_url: spec.frame_url,
        last_image_route: spec.frame_route || state.last_image_route,
        frame_urls: state.frame_urls ++ [spec.frame_url],
        director_conversation: spec.new_conv || state.director_conversation,
        performance_steps: [spec.step | state.performance_steps],
        style_stamped?: true,
        bootstrap_done?: true,
        recent_placements: Map.get(delta, :recent_placements, state.recent_placements),
        frames_since_style: Map.get(delta, :frames_since_style, state.frames_since_style),
        since_last_director: false,
        pending_pids: drop_dead(state.pending_pids)
    }

    maybe_speculate(state)
  end

  # Throw away the current look-ahead: kill its in-flight task and forget the
  # (never-adopted) frame. The conversation and canvas are untouched, so a
  # mis-prediction costs only a wasted render.
  defp discard_speculation(%{speculation: %{pid: pid}} = state) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)

    %{
      state
      | speculation: nil,
        pending_pids: state.pending_pids |> Enum.reject(&(&1 == pid)) |> MapSet.new()
    }
    |> discard_prerender()
  end

  defp discard_speculation(state), do: discard_prerender(%{state | speculation: nil})

  # The moment the active speculation is discarded (off-script singing, an
  # error), any deeper pre-rendered future is invalid too — it all chains off
  # the same img2img seed the discarded speculation was going to produce, and
  # off-script singing means that seed will never happen. Same honesty
  # principle as the single-slot discard: don't reveal, don't keep, a
  # mis-predicted future.
  defp discard_prerender(%{prerender: %{pid: pid}} = state) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)

    %{
      state
      | prerender: nil,
        prerendered: %{},
        pending_pids: state.pending_pids |> Enum.reject(&(&1 == pid)) |> MapSet.new()
    }
  end

  defp discard_prerender(state), do: %{state | prerender: nil, prerendered: %{}}

  # Kill an in-flight eager bootstrap render (e.g. lyrics reloaded mid-render —
  # the old one was built from stale lyrics) without touching anything else.
  defp discard_bootstrap_speculation(%{bootstrap_speculation: %{pid: pid}} = state) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)

    %{
      state
      | bootstrap_speculation: nil,
        pending_pids: state.pending_pids |> Enum.reject(&(&1 == pid)) |> MapSet.new()
    }
  end

  defp discard_bootstrap_speculation(state), do: %{state | bootstrap_speculation: nil}

  # Build the outbound `image` message and the derived latency numbers from a
  # finished render. Shared by the reactive :image_done handler and the
  # speculative one so both frames describe themselves identically.
  defp image_out(url, frames, prompt, timings) do
    # Provider round-trip (measured in the task) vs. mailbox wait, kept apart so
    # a backed-up pipeline doesn't read as a slow image provider.
    call_ms = Map.get(timings, :image_call_ms) || now_ms() - timings.image_started_at
    queue_ms = max(now_ms() - timings.image_started_at - call_ms, 0)
    dir_queue_ms = Map.get(timings, :director_queue_ms, 0)
    # The local morph (t2i + LOCAL_MORPH) runs after the cloud call inside the
    # same task, so subtract it out — otherwise its seconds are attributed to the
    # image provider and make a fast provider look slow.
    morph_ms = Map.get(timings, :morph_ms, 0)
    image_ms = max(call_ms - morph_ms, 0)
    route = Map.get(timings, :image_route)
    # "cloudflare" alone can't distinguish a 6-step Lightning frame from a
    # 20-step SD-1.5 i2i frame — show the route so the numbers are readable.
    label = route_of(timings)

    # Wall-clock the audience actually waits: every hop plus the queueing.
    total =
      (timings.stt_ms || 0) + timings.director_ms + dir_queue_ms + image_ms + morph_ms + queue_ms

    msg = %{
      type: "image",
      url: url,
      prompt: prompt,
      lyric: Map.get(timings, :lyric),
      ts: now_ms(),
      timings: %{
        stt_ms: timings.stt_ms,
        stt_provider: timings.stt_provider,
        director_ms: timings.director_ms,
        image_ms: image_ms,
        morph_ms: morph_ms,
        queue_ms: dir_queue_ms + queue_ms,
        total_ms: total,
        image_provider: label,
        image_model: route && route.model
      }
    }

    # Only attached when the provider produced a morph sequence (local SDXL);
    # absent otherwise so non-sidecar providers keep the old message shape.
    msg = if frames == [], do: msg, else: Map.put(msg, :frames, frames)

    # 0G verifiable-inference receipt, present only when the Director ran on 0G.
    receipt = Map.get(timings, :verification)
    msg = if receipt, do: Map.put(msg, :verification, receipt), else: msg

    %{
      msg: msg,
      route: route,
      receipt: receipt,
      image_ms: image_ms,
      morph_ms: morph_ms,
      queue_ms: queue_ms,
      dir_queue_ms: dir_queue_ms,
      total: total,
      label: label
    }
  end

  defp push(socket, msg), do: send(socket, {:push_json, msg})
  defp now_ms, do: System.system_time(:millisecond)
end
