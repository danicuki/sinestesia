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
       pending_pids: MapSet.new()
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
    {:noreply, %{state | fast: f}}
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

  # Reset all song-scoped state but KEEP open STT connections + socket.
  # Use when a new song starts mid-session — avoids reconnect roundtrip.
  # In-flight tasks from the previous song are invalidated via session_id.
  def handle_cast(:reset_song, state) do
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

    {:noreply,
     %{
       state
       | lyrics: [],
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
         pending_pids: MapSet.new()
     }}
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
    {:noreply, maybe_trigger(state)}
  end

  # Replay sessions can carry the style they were recorded with.
  def handle_info({:replay_style, style}, state) do
    apply_style(state, style, _from_curator? = false)
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

  def handle_info({:director_done, _result, _started_at, _call_ms, _model, sid}, %{session_id: cur} = state)
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
    provider = Sinestesia.ImageGen.provider() |> to_string()
    route = Map.get(timings, :image_route)

    # "cloudflare" alone can't distinguish a 6-step Lightning frame from a
    # 20-step SD-1.5 img2img frame — show the route so the numbers are readable.
    provider_label =
      case route do
        %{route: r, steps: s} -> "#{provider} #{r} #{s}st"
        _ -> provider
      end

    # Wall-clock the audience actually waits: every hop plus the queueing.
    total =
      (timings.stt_ms || 0) + timings.director_ms + dir_queue_ms + image_ms + morph_ms +
        queue_ms

    Logger.info(
      "[image:#{provider_label}#{if route, do: " #{route.model}", else: ""}] +#{image_ms}ms (morph #{morph_ms}ms, queue #{queue_ms}ms) (total #{total}ms = stt #{timings.stt_ms || 0} + director #{timings.director_ms} + dirq #{dir_queue_ms} + image #{image_ms} + morph #{morph_ms} + imgq #{queue_ms})"
    )

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
        # Local SDXL morph run after the cloud image (t2i + LOCAL_MORPH), broken
        # out so it isn't mistaken for image-provider latency.
        morph_ms: morph_ms,
        # Time spent waiting in the pipeline's mailbox rather than on a provider.
        # Non-zero here means we're the bottleneck, not the model.
        queue_ms: dir_queue_ms + queue_ms,
        total_ms: total,
        image_provider: provider_label,
        image_model: route && route.model
      }
    }

    # Only attached when the provider produced a morph sequence (local SDXL);
    # absent otherwise so non-sidecar providers keep the old message shape.
    msg = if frames == [], do: msg, else: Map.put(msg, :frames, frames)

    # 0G verifiable-inference receipt, present only when the Director ran on 0G.
    receipt = Map.get(timings, :verification)
    msg = if receipt, do: Map.put(msg, :verification, receipt), else: msg

    push(state.socket, msg)

    # On-chain settlement finishes after the answer is already on screen, so the
    # receipt above goes out as "pending". Chase the settled result and push it,
    # otherwise the badge sits on "verification pending" for the whole show.
    resolve_verification(receipt, state.socket)

    {:noreply,
     %{
       state
       | generating?: false,
         last_image_url: url,
         last_image_route: route || state.last_image_route,
         frame_urls: state.frame_urls ++ [url],
         style_stamped?: true,
         pending_pids: drop_dead(state.pending_pids)
     }}
  end

  def handle_info({:image_done, {:error, reason}, _timings, _sid}, state) do
    Logger.warning("[image] error: #{inspect(reason)}")
    {:noreply, %{state | generating?: false, pending_pids: drop_dead(state.pending_pids)}}
  end

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
        {"A single scene showing: #{prompt}. #{state.style}",
         %{state | frames_since_style: 0}}

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
      Logger.info("#{tag} #{inspect(state.style)} → #{inspect(new_style)} (resetting conversation)")

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

  defp which_providers do
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
        send(socket_pid, {:push_json, %{type: "error", message: "elevenlabs disabled: #{inspect(reason)}"}})
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
        send(socket_pid, {:push_json, %{type: "error", message: "deepgram disabled: #{inspect(reason)}"}})
        {:error, reason}
    end
  end

  defp start_stt(:local_whisper, socket_pid) do
    case Sinestesia.LocalWhisperSTT.start_link(self()) do
      {:ok, pid} ->
        Logger.info("[local_whisper] started")
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("[local_whisper] disabled: #{inspect(reason)} (is the sidecar running on :8002?)")
        send(socket_pid, {:push_json, %{type: "error", message: "local_whisper disabled: #{inspect(reason)}"}})
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
        send(socket_pid, {:push_json, %{type: "error", message: "replay disabled: #{inspect(reason)}"}})
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
  # Don't fire the Director on sub-word debris like "ul" (the tail of an
  # elongated "azuuuu...ul" split across STT segments) — it wastes a whole
  # image cycle on an atmospheric non-prompt. Real 2-word lines ("Vai voando")
  # still fire; skipped fragments aren't lost, they ride along in the next
  # window once more words arrive.
  @min_director_words 2

  defp maybe_trigger(%{generating?: true} = state), do: state
  defp maybe_trigger(%{since_last_director: false} = state), do: state

  defp maybe_trigger(state) do
    now = now_ms()
    bootstrap? = bootstrap?(state)

    cond do
      bootstrap? and accumulated_word_count(state) < @bootstrap_min_words ->
        # Wait until enough has been sung to seed a rich opening drawing.
        state

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
            pick_current_line(state, @window_words)
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
            if bootstrap?, do: Logger.info("[director] bootstrap fire with #{word_count(text)} words: #{inspect(text)}")
            pid = spawn_director(state, text)

            %{
              state
              | last_director_at: now,
                since_last_director: false,
                generating?: true,
                last_director_text: text,
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
    # Melody hint appended HERE (not to last_director_text) so the
    # duplicate-line guard keeps comparing raw lyrics.
    line = text <> melody_hint(state)
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
        send(parent, {:director_done, result, started_at, call_ms, Sinestesia.Director.last_model(), sid})
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

      send(parent, {:mint_done, do_mint(image_url, frame_urls, mode, performance)})
    end)
  end

  # One proof per Director step, aligned with the prompts: the 0G chat id and
  # whether its TEE signature verified. nil for steps that didn't run on 0G (the
  # chain falls back mid-song), which is itself worth recording honestly.
  defp resolve_proofs(steps) do
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
            verified: if(is_nil(verified), do: settled_verification(chat_id), else: verified)
          }

        _ ->
          nil
      end
    end)
  end

  # Ask the sidecar for a chat's settled verdict. Returns nil when it still
  # hasn't landed — recorded as "unresolved" rather than guessed either way.
  defp settled_verification(chat_id) when is_binary(chat_id) and chat_id != "" do
    url =
      System.get_env("ZEROG_SIDECAR_URL", "http://127.0.0.1:8788") <>
        "/v1/verification/" <> URI.encode(chat_id)

    case Req.get(url, receive_timeout: 3_000, retry: false) do
      {:ok, %{status: 200, body: %{"pending" => false, "verified" => v}}} -> v
      _ -> nil
    end
  end

  defp settled_verification(_), do: nil

  # Fill in song/artist from the lyrics before minting, so the NFT isn't stamped
  # "Untitled" forever. An explicit MINT_SONG/MINT_ARTIST (or a `song`/`artist`
  # option) always wins — identification only fills the blanks. Runs inside the
  # mint task, which is already off the pipeline's hot path.
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
        Logger.info("[songid] no identification (#{inspect(reason)}); minting as Untitled")

        %{
          performance
          | song: presence(performance.song) || "Untitled",
            artist: presence(performance.artist) || default_artist()
        }
    end
  end

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

  defp pick_current_line(state, window \\ @window_words) do
    # Pick the text from whichever provider updated MOST RECENTLY, then take
    # the trailing N words. This is robust to both segmenting providers
    # (Deepgram → short fragment, we keep all) and accumulating providers
    # (ElevenLabs → long running transcript, we keep only the end).
    state.last_text_at
    |> Enum.map(fn {provider, ts} ->
      raw = Map.get(state.last_interims, provider, "")
      {ts, last_n_words(raw, window)}
    end)
    |> Enum.reject(fn {_, text} -> text == "" end)
    |> case do
      [] ->
        ""

      candidates ->
        {_ts, text} = Enum.max_by(candidates, fn {ts, _} -> ts end)
        text
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


  defp spawn_image(prompt, timings, prev_url, sid, camera, extra \\ []) do
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
          # Which model actually rendered this frame (routes differ wildly in cost).
          |> Map.put(:image_route, Sinestesia.ImageGen.last_route())

        send(parent, {:image_done, result, timings, sid})
      end)

    pid
  end

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

  defp push(socket, msg), do: send(socket, {:push_json, msg})
  defp now_ms, do: System.system_time(:millisecond)
end
