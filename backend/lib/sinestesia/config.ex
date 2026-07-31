defmodule Sinestesia.Config do
  @moduledoc """
  The one place that knows every knob Sinestesia reads from the environment.

  Settings are read all over the codebase, right where they're used
  (`System.get_env("CLOUDFLARE_STEPS", "20")` inside the Cloudflare provider),
  which is good — the default lives next to the code it affects. What was
  missing is anything that knows the *whole set*. So the boot log announced one
  arbitrary setting, `CONFIGURATION.md` drifted years behind the code, and the
  only way to answer "what is this box actually running?" was to grep.

  This module is that missing index: one entry per setting, carrying its env
  var, default, accepted values and a one-line description. From it we derive

    * the boot banner (`log_boot/0`) — everything that is live, right now;
    * `GET /config` and `mix sinestesia.config`;
    * `CONFIGURATION.md` (`mix sinestesia.config --markdown`).

  It does NOT resolve the values — the owning module still does that, so there
  is exactly one implementation of each default and no chance of the index
  disagreeing with the code. Where a setting is normalised or where several
  combine into what actually ran (Director provider *and* model), `resolved/0`
  calls the real accessor rather than re-reading the env.

  ## Adding a setting

  Add it here in the same commit that reads it. `test/config_test.exs` fails the
  build if `lib/` reads an env var this table doesn't list, or if
  `CONFIGURATION.md` is out of date — regenerate with:

      mix sinestesia.config --write
  """
  require Logger

  @typedoc "One environment setting: what it is, where it's read, what it accepts."
  @type spec :: %{
          key: String.t(),
          group: atom(),
          default: String.t() | nil,
          values: String.t() | nil,
          secret: boolean(),
          doc: String.t()
        }

  @groups [
    server: "Server",
    keys: "API keys",
    stt: "Speech-to-text",
    director: "Director (LLM)",
    image: "Image generation",
    cloudflare: "Cloudflare Workers AI",
    local_sdxl: "Local SDXL sidecar",
    scene: "Scene & style",
    lookahead: "Predictive look-ahead",
    library: "Song library",
    mint: "Mint & provenance",
    songid: "Song identification",
    replay: "Replay & benchmarks"
  ]

  # Order within a group is the order it prints. Keep the most decision-shaping
  # setting (the provider switch) first in each group.
  @specs [
    # ── Server ──────────────────────────────────────────────────────────────
    %{
      key: "PORT",
      group: :server,
      default: "4000",
      values: "any port",
      doc: "HTTP + WebSocket port for the backend."
    },
    %{
      key: "STRICT_CONFIG",
      group: :server,
      default: nil,
      values: "1 | true",
      doc:
        "Refuse to boot if any switch was silently downgraded (e.g. i2i on a provider that can't do it). Worth setting for a rehearsal."
    },

    # ── API keys ────────────────────────────────────────────────────────────
    %{
      key: "ELEVENLABS_API_KEY",
      group: :keys,
      secret: true,
      doc: "ElevenLabs Scribe realtime STT. Required for STT_PROVIDER=elevenlabs."
    },
    %{
      key: "DEEPGRAM_API_KEY",
      group: :keys,
      secret: true,
      doc: "Deepgram streaming STT. Required for STT_PROVIDER=deepgram."
    },
    %{
      key: "FAL_API_KEY",
      group: :keys,
      secret: true,
      doc: "fal.ai. Required for IMAGE_PROVIDER=fal."
    },
    %{
      key: "GOOGLE_API_KEY",
      group: :keys,
      secret: true,
      doc:
        "Google AI Studio. Used by DIRECTOR_PROVIDER=gemini, IMAGE_PROVIDER=google, and song identification."
    },
    %{
      key: "ANTHROPIC_API_KEY",
      group: :keys,
      secret: true,
      doc: "Anthropic. Used by DIRECTOR_PROVIDER=haiku and as the song-identification fallback."
    },
    %{
      key: "CLOUDFLARE_ACCOUNT_ID",
      group: :keys,
      secret: true,
      doc: "Cloudflare account. Required for IMAGE_PROVIDER=cloudflare."
    },
    %{
      key: "CLOUDFLARE_API_TOKEN",
      group: :keys,
      secret: true,
      doc: "Cloudflare Workers AI token. Required for IMAGE_PROVIDER=cloudflare."
    },

    # ── STT ─────────────────────────────────────────────────────────────────
    %{
      key: "STT_PROVIDER",
      group: :stt,
      default: "elevenlabs",
      values: "elevenlabs | deepgram | both | local_whisper | replay",
      doc: "Which speech-to-text engine transcribes the singing."
    },
    %{
      key: "ELEVEN_MODEL",
      group: :stt,
      default: "scribe_v2_realtime",
      doc: "ElevenLabs streaming model."
    },
    %{
      key: "ELEVEN_LANG",
      group: :stt,
      default: "pt",
      values: "ISO-639-1",
      doc: "Language hint for ElevenLabs. Wrong language wrecks Portuguese lyrics."
    },
    %{
      key: "ELEVEN_COMMIT",
      group: :stt,
      default: "vad",
      values: "vad | manual",
      doc: "How a transcript segment is closed: voice-activity detection, or explicit commits."
    },
    %{
      key: "ELEVEN_VAD_SILENCE",
      group: :stt,
      default: "0.6",
      values: "seconds",
      doc: "Silence before VAD commits a line. Lower = more responsive, more fragments."
    },
    %{
      key: "ELEVEN_NO_VERBATIM",
      group: :stt,
      default: nil,
      values: "1 | true | on",
      doc:
        "Ask Scribe to clean the transcript instead of returning it verbatim. Off by default: its documented job is removing filler words, REPEATED PHRASES and stuttering, and a song repeats on purpose — stripping a returning chorus would remove the very signal PerformanceFollower uses to place the singer. Worth measuring on a real run for the false starts a live mic produces, but it is not the fix for held vowels (\"castelooo\"): the docs never claim it normalizes those, so the follower's own repeated-letter collapse stays on regardless and also covers the Deepgram and local-Whisper paths, which have no equivalent option."
    },
    %{
      key: "LOCAL_WHISPER_HOST",
      group: :stt,
      default: "127.0.0.1",
      doc: "Host of the local Whisper sidecar (STT_PROVIDER=local_whisper)."
    },
    %{
      key: "LOCAL_WHISPER_PORT",
      group: :stt,
      default: "8002",
      doc: "Port of the local Whisper sidecar."
    },
    %{
      key: "LOCAL_WHISPER_PATH",
      group: :stt,
      default: "/transcribe",
      doc: "Transcription path on the local Whisper sidecar."
    },

    # ── Director ────────────────────────────────────────────────────────────
    %{
      key: "DIRECTOR_PROVIDER",
      group: :director,
      default: "gemma",
      values: "gemma | gemini | haiku | zerog (alias: 0g)",
      doc:
        "Which LLM turns each sung line into a scene prompt. Falls through the chain on failure."
    },
    %{
      key: "OLLAMA_URL",
      group: :director,
      default: "http://localhost:11434",
      doc: "Ollama endpoint for DIRECTOR_PROVIDER=gemma."
    },
    %{
      key: "OLLAMA_MODEL",
      group: :director,
      default: "gemma4:12b-mlx",
      doc: "Model name inside Ollama. Only meaningful when the provider is gemma."
    },
    %{
      key: "GEMINI_MODEL",
      group: :director,
      default: "gemini-3.1-flash-lite",
      doc: "Model for DIRECTOR_PROVIDER=gemini."
    },
    %{
      key: "ZEROG_SIDECAR_URL",
      group: :director,
      default: "http://127.0.0.1:8788",
      doc:
        "Local 0G Compute sidecar (zerog/) for verifiable inference; also polled for settled verifications."
    },
    %{
      key: "DIRECTOR_MIN_INTERVAL_MS",
      group: :director,
      default: nil,
      values: "milliseconds",
      doc: "Floor between Director calls. Unset = no throttle (fire on every committed line)."
    },

    # ── Image ───────────────────────────────────────────────────────────────
    %{
      key: "IMAGE_PROVIDER",
      group: :image,
      default: "fal",
      values: "fal | cloudflare (cf) | google | pollinations | local_sdxl (local)",
      doc: "Which service renders the frames."
    },
    %{
      key: "RENDER_MODE",
      group: :image,
      default: "i2i",
      values: "i2i (aliases: img2img, image2image) | t2i (aliases: text2img, txt2img)",
      doc:
        "i2i evolves the previous frame (continuity, slower). t2i re-renders each frame from the scene prompt (no drift, faster)."
    },
    %{
      key: "FAL_TIMEOUT_MS",
      group: :image,
      default: "15000",
      doc:
        "Per-frame budget on fal. Past it the frame is abandoned and re-rendered as t2i rather than dropped."
    },
    %{
      key: "IMAGE_MODE",
      group: :image,
      default: "story",
      values: "story | classic",
      doc:
        "story accumulates scene elements across the song; classic redraws each line independently."
    },
    %{
      key: "COMPOSE_MODE",
      group: :image,
      default: "inpaint",
      values: "inpaint | global",
      doc:
        "In story mode, whether new elements are inpainted into a region or the whole frame is re-composed."
    },
    %{
      key: "LOCAL_MORPH",
      group: :image,
      default: "true",
      values: "true | 1 | yes | false",
      doc:
        "After a t2i frame, run the local SDXL sidecar to morph from the previous frame. Costs extra seconds; adds in-between frames."
    },
    %{
      key: "GOOGLE_IMAGE_MODEL",
      group: :image,
      default: "imagen-4.0-fast-generate-001",
      doc: "Imagen model for IMAGE_PROVIDER=google."
    },

    # ── Cloudflare ──────────────────────────────────────────────────────────
    %{
      key: "CLOUDFLARE_T2I_MODEL",
      group: :cloudflare,
      default: "@cf/bytedance/stable-diffusion-xl-lightning",
      doc: "Model for text-to-image frames on Workers AI."
    },
    %{
      key: "CLOUDFLARE_T2I_STEPS",
      group: :cloudflare,
      default: "6",
      doc: "Steps for the t2i model. Lightning is built for ~6; raising it buys nothing."
    },
    %{
      key: "CLOUDFLARE_IMG2IMG_MODEL",
      group: :cloudflare,
      default: "@cf/runwayml/stable-diffusion-v1-5-img2img",
      doc: "Model for image-to-image frames on Workers AI."
    },
    %{
      key: "CLOUDFLARE_STEPS",
      group: :cloudflare,
      default: "20",
      doc: "Steps for the i2i model. This is the single biggest lever on i2i frame time."
    },
    %{
      key: "CLOUDFLARE_STRENGTH",
      group: :cloudflare,
      default: "0.7",
      values: "0.0-1.0",
      doc: "How far an i2i frame may travel from the previous one."
    },
    %{
      key: "CLOUDFLARE_GUIDANCE",
      group: :cloudflare,
      default: "7.5",
      doc: "Classifier-free guidance: how strictly the image obeys the prompt."
    },

    # ── Local SDXL ──────────────────────────────────────────────────────────
    %{
      key: "LOCAL_SDXL_URL",
      group: :local_sdxl,
      default: "http://127.0.0.1:8003",
      doc:
        "Local SDXL Turbo sidecar (local-sdxl/). Used for IMAGE_PROVIDER=local_sdxl and for LOCAL_MORPH."
    },
    %{
      key: "LOCAL_SDXL_STRENGTH",
      group: :local_sdxl,
      default: "0.78",
      values: "0.0-1.0",
      doc: "img2img strength on the local sidecar."
    },
    %{
      key: "LOCAL_SDXL_STEPS",
      group: :local_sdxl,
      default: "3",
      doc: "Steps on the local sidecar. Turbo is designed for very few."
    },

    # ── Scene & style ───────────────────────────────────────────────────────
    %{
      key: "SCENE_WINDOW",
      group: :scene,
      default: "5",
      doc: "How many scene elements the Director carries forward in story mode."
    },
    %{
      key: "STYLE_ANCHOR",
      group: :scene,
      default: nil,
      doc: "Force a visual style for the whole show. Unset = the curator picks one per song."
    },
    %{
      key: "STYLE_REFRESH_EVERY",
      group: :scene,
      default: "4",
      doc: "Re-stamp the style phrase into the prompt every N frames, so it doesn't drift away."
    },
    %{
      key: "COMPOSE_ATMOS_STRENGTH",
      group: :scene,
      default: "0.4",
      values: "0.0-1.0",
      doc: "Weight of the atmosphere/mood pass when composing a frame."
    },

    # ── Predictive look-ahead ─────────────────────────────────────────────────
    %{
      key: "SPECULATIVE_LOOKAHEAD",
      group: :lookahead,
      default: nil,
      values: "1 | true | on",
      doc:
        "When the operator has pasted the song's lyrics (the `lyrics` WS message), render the predicted NEXT line ahead of time and hold it, revealing it only when STT confirms that line was sung. Off = today's reactive behaviour."
    },
    %{
      key: "LYRIC_MATCH_THRESHOLD",
      group: :lookahead,
      default: "0.6",
      values: "0.0-1.0",
      doc:
        "Word-overlap similarity a sung line needs to be considered a match for a pasted lyric line. Lower tolerates looser singing; too low misfires on the wrong line."
    },
    %{
      key: "LYRIC_WINDOW",
      group: :lookahead,
      default: "3",
      doc:
        "How many lyric lines ahead of the current position the follower will look, so a skipped line is still found."
    },
    %{
      key: "MUSICAL_STRUCTURE",
      group: :lookahead,
      default: nil,
      values: "1 | true | on",
      doc:
        "Detect verse/chorus/bridge/outro from the pasted lyrics' blank-line stanzas, track which section the confirmed singing is in, and append a short structural hint to the Director's line (e.g. \"chorus returns\") so a returning chorus can echo its established imagery via the Director's own conversation memory. Independent of SPECULATIVE_LOOKAHEAD — works whenever lyrics are loaded."
    },
    %{
      key: "LOOKAHEAD_DEPTH",
      group: :lookahead,
      default: "1",
      values: "positive integer",
      doc:
        "How many lyric lines SPECULATIVE_LOOKAHEAD is allowed to pre-render ahead of the singer (chained sequentially — i2i needs the previous frame, so this can never parallelize). 1 (default) is Phase 1's original one-line lookahead, exactly. Above 1, the pipeline races further ahead in a background cache whenever there's a head start (e.g. lyrics loaded during an instrumental intro); every frame is still revealed only on STT confirmation. Deeper values mean more frames are generated well before they're sung — read this alongside how the mint certificate / any marketing describes \"how live\" the show is."
    },
    %{
      key: "LYRICS_CHUNK_GEMINI_MODEL",
      group: :lookahead,
      default: "gemini-3.5-flash-lite",
      doc:
        "Model asked to split a loaded song's full lyrics into visually coherent scene units (see Sinestesia.LyricsChunker), replacing the old fixed-word/fixed-line guess with a real per-song read of the whole text. Unlike SONGID_GEMINI_MODEL, this task needs no real-world knowledge — just fast structural reading of text it's already given — so it defaults to a lite tier rather than the non-lite model song ID needs. A non-lite model measured live spending the whole timeout budget on 'thinking' before answering, so every chunking call fell back to one-line-per-chunk every time — the exact thinness this feature exists to fix; gemini-3.5-flash-lite confirmed live to resolve in time. Runs once per song, off the critical path — never blocks a render."
    },
    %{
      key: "LYRICS_CHUNK_ANTHROPIC_MODEL",
      group: :lookahead,
      default: "claude-haiku-4-5",
      doc: "Fallback model for lyrics chunking. Needs ANTHROPIC_API_KEY."
    },
    %{
      key: "LYRICS_CHUNK_TIMEOUT_MS",
      group: :lookahead,
      default: "15000",
      doc:
        "Per-attempt budget for lyrics chunking. Runs fully off the critical path — the eager bootstrap always renders off the one-line-per-chunk fallback the instant lyrics load and only upgrades later if this resolves in time — so a generous budget costs nothing but a later upgrade; too short just means the smarter split never gets a chance to land before it matters."
    },

    # ── Song library ────────────────────────────────────────────────────────
    %{
      key: "SONGS_DIR",
      group: :library,
      default: "../songs",
      doc:
        "Where Sinestesia.SongLibrary stores/reads known songs (one JSON file per song). Default is relative to the backend's working directory, same convention as tests/sessions/ for replay."
    },
    %{
      key: "SONG_AUTO_IDENTIFY",
      group: :library,
      default: nil,
      values: "1 | true | on",
      doc:
        "When no lyrics/setlist is loaded, try to identify the song from the first few sung words by matching against every song's opening line in the library. On a confident match, loads that song's lyrics mid-stream (same eager-bootstrap/look-ahead machinery as loading it by hand). A wrong guess costs a discarded speculative render, never worse than not guessing — but the fewer words waited for, the higher the misidentification risk, so this is opt-in."
    },
    %{
      key: "SONG_IDENTIFY_THRESHOLD",
      group: :library,
      default: "0.7",
      values: "0.0-1.0",
      doc:
        "Word-overlap similarity a few sung words need against a library song's opening line to auto-identify it. Higher than LYRIC_MATCH_THRESHOLD by default — a short fragment matched against MANY candidate songs is inherently more ambiguous than matching one already-known song's next line."
    },

    # ── Mint ────────────────────────────────────────────────────────────────
    %{
      key: "MINT_SIDECAR_URL",
      group: :mint,
      default: "http://127.0.0.1:8790",
      doc: "Sui mint sidecar (sui/mint/). Receives the finished performance and mints the NFT."
    },
    %{
      key: "MINT_COMPOSE",
      group: :mint,
      default: "webp",
      values: "webp | gif | collage | final",
      doc: "How the song's frames become one NFT image."
    },
    %{
      key: "MINT_SONG",
      group: :mint,
      default: nil,
      doc: "Force the song title. Unset = identified from the lyrics (see SONGID_*)."
    },
    %{
      key: "MINT_ARTIST",
      group: :mint,
      default: "Sinestesia",
      doc:
        "Performing artist credited on the NFT, and the fallback when identification finds no artist."
    },
    %{
      key: "MINT_VENUE",
      group: :mint,
      default: "Live",
      doc: "Venue recorded in the provenance record."
    },

    # ── Song ID ─────────────────────────────────────────────────────────────
    %{
      key: "SONGID_GEMINI_MODEL",
      group: :songid,
      default: "gemini-3.6-flash",
      doc:
        "First model asked to name the performed song. Needs real world knowledge, so not a lite tier."
    },
    %{
      key: "SONGID_ANTHROPIC_MODEL",
      group: :songid,
      default: "claude-haiku-4-5",
      doc: "Fallback model for song identification. Needs ANTHROPIC_API_KEY."
    },
    %{
      key: "SONGID_TIMEOUT_MS",
      group: :songid,
      default: "30000",
      doc:
        "Per-attempt budget. Off the hot path, so generous — a clipped answer mints as \"Untitled\" forever."
    },
    %{
      key: "SONGID_ALLOW_LOCAL",
      group: :songid,
      default: nil,
      values: "1 | true",
      doc:
        "Let the local model name songs. Off by default: it invents confident, wrong titles that get minted permanently."
    },

    # ── Replay & bench ──────────────────────────────────────────────────────
    %{
      key: "REPLAY_FILE",
      group: :replay,
      default: nil,
      doc: "Recorded session to replay instead of live audio (STT_PROVIDER=replay)."
    },
    %{
      key: "REPLAY_SPEED",
      group: :replay,
      default: "1.0",
      doc: "Playback rate for a replayed session."
    },
    %{
      key: "REPLAY_PORT",
      group: :replay,
      default: "4999",
      doc: "Port used by `mix sinestesia.replay`."
    },
    %{
      key: "BENCH_PORT",
      group: :replay,
      default: "4998",
      doc: "Port used by `mix sinestesia.bench`."
    },
    %{
      key: "BENCH_OUT",
      group: :replay,
      default: "bench-<timestamp>",
      doc: "Output directory for benchmark runs."
    }
  ]

  @doc "Every setting Sinestesia reads, in display order."
  @spec specs() :: [spec()]
  def specs do
    Enum.map(@specs, fn s ->
      s
      |> Map.put_new(:default, nil)
      |> Map.put_new(:values, nil)
      |> Map.put_new(:secret, false)
    end)
  end

  @doc "Group keys paired with their human-readable titles, in display order."
  def groups, do: @groups

  @doc """
  Every setting with its live value and where that value came from.

  `source` is `:env` when the process environment (or `.env`) set it and
  `:default` when nothing did — the distinction is the whole point of the boot
  banner, because "this is what you configured" and "this is what you got" are
  different questions.
  """
  @spec resolved() :: [map()]
  def resolved do
    Enum.map(specs(), fn spec ->
      case System.get_env(spec.key) do
        v when is_binary(v) and v != "" ->
          Map.merge(spec, %{value: v, source: :env})

        _ ->
          Map.merge(spec, %{value: spec.default, source: :default})
      end
    end)
  end

  @doc """
  What the pipeline will *actually* do, as opposed to what was configured.

  `DIRECTOR_PROVIDER=zerog` with `OLLAMA_MODEL=gemma4:12b-mlx` set is not a
  contradiction — the second is simply inert. Printing the raw env vars side by
  side invites exactly the misreading that the old boot line made
  ("Director: gemma4:12b-mlx" while running on 0G), so resolve provider and
  model together, through the same accessors the pipeline uses.
  """
  @spec effective() :: [{String.t(), String.t()}]
  def effective do
    cfg = Application.fetch_env!(:sinestesia, :config)
    director = Sinestesia.Director.provider()

    director_model =
      case director do
        :gemma -> Keyword.get(cfg, :ollama_model)
        :gemini -> System.get_env("GEMINI_MODEL", "gemini-3.1-flash-lite")
        :haiku -> "claude-haiku-4-5"
        :zerog -> "(chosen by the 0G sidecar)"
      end

    # The image line reports the mode that will run, not the one requested, and
    # says so when they differ — the whole point of the capability table.
    requested = Sinestesia.ImageGen.requested_render_mode()
    mode = Sinestesia.ImageGen.render_mode()

    mode_note =
      if mode == requested, do: "", else: " (RENDER_MODE=#{requested} not supported here)"

    # How a Director reply is turned into an image request: element deltas that
    # get inpainted, or a whole-scene prompt.
    shape = if Sinestesia.Director.compose?(), do: "element inpaints", else: "whole-scene prompts"

    [
      {"stt", Sinestesia.Pipeline.which_providers() |> Enum.map_join(" + ", &to_string/1)},
      {"director", "#{director} · #{director_model}"},
      {"image", "#{Sinestesia.ImageGen.provider()} · #{mode}#{mode_note}"},
      {"scene",
       "#{Sinestesia.Director.mode()} mode, window #{Sinestesia.Director.scene_window()}, #{shape}"}
    ]
  end

  @doc """
  Combinations that were asked for but can't be delivered, and what we did.

  The three image switches are independent, but not every combination exists —
  Imagen has no image-to-image endpoint, only fal and the local sidecar can
  inpaint. Those requests used to be honoured in silence: the previous frame
  and the placement were discarded, and story mode's `NEW: <element>` deltas
  became the entire prompt for an independent render, so the song came out as
  unrelated objects on unrelated canvases with the style re-invented each time.
  Nothing in the logs said so.

  Each entry is `{severity, message}`. `:downgrade` means we resolved it and
  carried on; `:error` means the configuration cannot run at all. Set
  `STRICT_CONFIG=1` to refuse to boot on either — worth doing for a rehearsal,
  where finding out now beats finding out on stage.
  """
  @spec conflicts() :: [{:downgrade | :error, String.t()}]
  def conflicts do
    provider = Sinestesia.ImageGen.provider()
    caps = Sinestesia.ImageGen.capabilities(provider)
    requested = Sinestesia.ImageGen.requested_render_mode()
    compose_requested = System.get_env("COMPOSE_MODE", "inpaint") != "global"
    story? = Sinestesia.Director.mode() == :story

    []
    |> then(fn acc ->
      if requested == :i2i and not caps.i2i do
        [
          {:downgrade,
           "RENDER_MODE=i2i, but #{provider} has no image-to-image endpoint — running t2i. " <>
             "Every frame is rendered from the full scene prompt; there is no previous-frame continuity."}
          | acc
        ]
      else
        acc
      end
    end)
    |> then(fn acc ->
      if story? and compose_requested and not caps.inpaint do
        [
          {:downgrade,
           "COMPOSE_MODE=inpaint, but #{provider} cannot inpaint — using whole-scene prompts. " <>
             "Set COMPOSE_MODE=global to make this explicit, or use fal/local_sdxl to inpaint."}
          | acc
        ]
      else
        acc
      end
    end)
    |> then(fn acc ->
      if not caps.t2i do
        [
          {:error, "#{provider} cannot render text-to-image; there is no way to open a song."}
          | acc
        ]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Print the whole configuration at boot.

  Deliberately one log call: interleaving this with the supervisor's own startup
  chatter is how it became unreadable in the first place.
  """
  def log_boot do
    Logger.info("\n" <> banner())

    # Repeated outside the banner, at warning level: a downgrade is the kind of
    # thing that explains a whole bad show, and it must not scroll past looking
    # like one more line of a large info block.
    for {severity, message} <- conflicts() do
      case severity do
        :error -> Logger.error("[config] #{message}")
        :downgrade -> Logger.warning("[config] #{message}")
      end
    end

    enforce_strict!()
  end

  # STRICT_CONFIG turns "we quietly coped" into "we refuse to start". The right
  # setting for a rehearsal or CI; the wrong one for five minutes before a set,
  # which is why it's opt-in.
  defp enforce_strict! do
    strict? = System.get_env("STRICT_CONFIG") in ["1", "true"]
    problems = conflicts()

    cond do
      problems == [] ->
        :ok

      strict? ->
        raise """
        Configuration cannot be delivered as requested, and STRICT_CONFIG is set:

          #{problems |> Enum.map_join("\n  ", fn {_, m} -> m end)}

        Fix the combination, or unset STRICT_CONFIG to run with the downgrades above.
        """

      Enum.any?(problems, &match?({:error, _}, &1)) ->
        raise "Configuration is unusable: #{problems |> Enum.filter(&match?({:error, _}, &1)) |> Enum.map_join("; ", fn {_, m} -> m end)}"

      true ->
        :ok
    end
  end

  @doc "The boot banner as a string (also served by `GET /config` and `mix sinestesia.config`)."
  def banner do
    all = resolved()

    body =
      @groups
      |> Enum.map(fn {group, title} ->
        rows = Enum.filter(all, &(&1.group == group))
        if rows == [], do: nil, else: [" " <> title, Enum.map(rows, &row/1)]
      end)
      |> Enum.reject(&is_nil/1)

    head =
      Enum.map(effective(), fn {label, value} ->
        "  " <> String.pad_trailing(label, 10) <> value
      end)

    notes =
      case conflicts() do
        [] ->
          []

        problems ->
          ["├─ NOT AS REQUESTED" | Enum.map(problems, fn {_, m} -> "  ! " <> m end)]
      end

    [
      "┌─ Sinestesia configuration ─────────────────────────────────────────",
      head,
      notes,
      "├─ settings  (* = set in the environment, everything else is a default)",
      body,
      "└─ full reference: CONFIGURATION.md · live: GET /config"
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp row(%{source: source} = s) do
    mark = if source == :env, do: "*", else: " "
    "  #{mark} #{String.pad_trailing(s.key, 26)} #{display(s)}"
  end

  # Never print a key. Show enough to tell two keys apart and to prove the right
  # file was loaded, and nothing more — this banner ends up in shared logs and
  # in screen-recorded demos.
  defp display(%{value: nil}), do: "(unset)"

  defp display(%{secret: true, value: v}) do
    "set (#{String.slice(v, 0, 4)}…#{String.slice(v, -4, 4)}, #{String.length(v)} chars)"
  end

  defp display(%{value: v}), do: v

  @doc """
  The configuration as JSON-ready data, for `GET /config`.

  Secrets are reduced to a boolean: the endpoint is unauthenticated and the
  laptop running it is on conference wifi.
  """
  def to_map do
    settings =
      Map.new(resolved(), fn s ->
        {s.key,
         %{
           value: if(s.secret, do: nil, else: s.value),
           set: s.source == :env,
           default: if(s.secret, do: nil, else: s.default),
           group: s.group,
           values: s.values,
           doc: s.doc
         }}
      end)

    %{
      effective: Map.new(effective()),
      conflicts: Enum.map(conflicts(), fn {severity, m} -> %{severity: severity, message: m} end),
      capabilities: Sinestesia.ImageGen.capabilities(),
      settings: settings
    }
  end

  @doc """
  Regenerate the settings reference in `CONFIGURATION.md`.

  Generated rather than hand-written because a hand-written table is a promise
  someone has to keep on every commit, and this one wasn't kept.
  """
  def markdown do
    all = resolved()

    tables =
      @groups
      |> Enum.map(fn {group, title} ->
        rows = Enum.filter(all, &(&1.group == group))

        if rows == [] do
          nil
        else
          [
            "### #{title}\n",
            "| Variable | Default | Accepts | Description |",
            "| --- | --- | --- | --- |",
            Enum.map(rows, fn s ->
              "| `#{s.key}` | #{md_default(s)} | #{md_values(s)} | #{s.doc} |"
            end),
            ""
          ]
        end
      end)
      |> Enum.reject(&is_nil/1)

    [
      "<!-- GENERATED by `mix sinestesia.config --write`. Edit backend/lib/sinestesia/config.ex, not this section. -->\n",
      tables
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp md_default(%{secret: true}), do: "_none_"
  defp md_default(%{default: nil}), do: "_unset_"
  defp md_default(%{default: d}), do: "`#{d}`"

  defp md_values(%{values: nil}), do: "—"
  defp md_values(%{values: v}), do: v |> String.replace("|", "\\|") |> then(&"`#{&1}`")
end
