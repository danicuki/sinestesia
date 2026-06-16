# 🎛️ Sinestesia Configuration Reference

This document serves as the single source of truth for all environment variables, provider switches, hyperparameters, and local sidecar settings. By customizing these flags in your `.env` file or process environment, you can tailor Sinestesia's real-time performance, latencies, model parameters, and generation characteristics to your local hardware capabilities.

---

## 🗺️ Quick Reference Table

| Category | Environment Variable | Default Value | Supported Values / Range | Description |
| :--- | :--- | :--- | :--- | :--- |
| **Ports** | `PORT` | `4000` | Any valid port | Local HTTP/WebSocket server port. |
| **STT** | `STT_PROVIDER` | `elevenlabs` | `elevenlabs` \| `deepgram` \| `both` \| `local_whisper` \| `replay` | Selects speech-to-text engine. |
| **Director** | `DIRECTOR_PROVIDER` | `gemma` | `gemma` (local) \| `gemini` \| `haiku` | Selects LLM to generate prompt compositions. |
| **Image** | `IMAGE_PROVIDER` | `fal` | `fal` \| `local_sdxl` \| `google` \| `pollinations` \| `cloudflare` | Selects image generator. |
| **Image** | `IMAGE_MODE` | `story` | `story` (accumulative) \| `classic` (independent) | Determines whether scene grows or re-draws. |

---

## 🔑 1. Core API Keys & Ports

These form the foundation of Sinestesia's external API integrations and local routing.

### `PORT`
* **Default**: `4000`
* **Description**: The port on which the Elixir backend starts its Plug/Bandit server, serving the API and WebSocket listeners.

### `ELEVENLABS_API_KEY`
* **Default**: _None_
* **Description**: API key required for ElevenLabs Scribe v2 Realtime streaming speech-to-text.

### `FAL_API_KEY`
* **Default**: _None_
* **Description**: API key required if using `IMAGE_PROVIDER=fal` (highly recommended for ultra-fast, cloud-based Flux Schnell/Dev).

### `GOOGLE_API_KEY`
* **Default**: _None_
* **Description**: API key required if using `IMAGE_PROVIDER=google` (Imagen 4) or `DIRECTOR_PROVIDER=gemini` (Gemini 2.5 Flash). Get a key from [Google AI Studio](https://aistudio.google.com/).

### `ANTHROPIC_API_KEY`
* **Default**: _None_
* **Description**: API key required if using `DIRECTOR_PROVIDER=haiku` (Claude 4.5 Haiku) as your Director LLM or fallback.

### `OLLAMA_URL`
* **Default**: `http://localhost:11434`
* **Description**: Endpoint of your local Ollama server running Gemma.

### `OLLAMA_MODEL`
* **Default**: `gemma4:12b-mlx`
* **Description**: The specific model name loaded in Ollama when `DIRECTOR_PROVIDER=gemma`.

---

## 🎙️ 2. Speech-to-Text (STT) Provider Controls

Sinestesia handles real-time audio downsampling to 16 kHz and streams binary PCM frames into your selected STT provider.

### `STT_PROVIDER`
* **Default**: `elevenlabs`
* **Supported Options**:
  * `elevenlabs`: Cloud-based ElevenLabs Scribe v2 Realtime streaming WebSocket.
  * `deepgram`: Cloud-based Deepgram Nova-3 streaming WebSocket.
  * `both`: Streams audio to **both** ElevenLabs and Deepgram simultaneously. Both sets of transcripts are pushed to the frontend with distinct tags, allowing side-by-side A/B latency and accuracy comparison.
  * `local_whisper`: Zero-cost, local streaming MLX-accelerated Whisper sidecar.
  * `replay`: Headless simulation mode. Loads a recorded transcription stream from a JSON file.

### 🎛️ ElevenLabs STT Configurations
These flags are used when `STT_PROVIDER` is set to `elevenlabs` or `both`:

* **`ELEVEN_MODEL`** (Default: `scribe_v2_realtime`): The model used by ElevenLabs.
* **`ELEVEN_LANG`** (Default: `pt`): Language code (e.g., `pt` for Portuguese, `en` for English).
* **`ELEVEN_COMMIT`** (Default: `vad`): Commit mode.
  * `vad`: Voice Activity Detection auto-commits speech segments on trailing silence.
  * `manual`: Commits must be sent manually.
* **`ELEVEN_VAD_SILENCE`** (Default: `0.6`): Seconds of trailing silence before the ElevenLabs endpoint commits a partial segment as a final lyric block.

### 🎛️ Local Whisper STT configurations
These flags are used when `STT_PROVIDER` is set to `local_whisper` to communicate with the Whisper sidecar:

* **`LOCAL_WHISPER_HOST`** (Default: `127.0.0.1`): IP address of the Python Whisper sidecar server.
* **`LOCAL_WHISPER_PORT`** (Default: `8002`): WebSocket port of the Whisper sidecar.
* **`LOCAL_WHISPER_PATH`** (Default: `/transcribe`): Endpoint path for transcription.

---

## 🎬 3. Director LLM Configuration

The "Director" is the orchestrating LLM. It receives the accumulated song lyrics, remembers what is already drawn on the canvas, and outputs a revised, detailed image prompt describing the entire accumulated scene.

### `DIRECTOR_PROVIDER`
* **Default**: `gemma`
* **Supported Options**:
  * `gemma`: Sovereign, on-device local Gemma 4 12B via Ollama. It has zero cost and extremely low latency (~800ms) with MLX-acceleration.
  * `gemini`: Google Gemini 2.5 Flash API (~300-500ms latency, high prompt compliance).
  * `haiku`: Claude 4.5 Haiku API (~300ms latency).
* > [!NOTE]
  > If the primary `DIRECTOR_PROVIDER` times out (>1500ms), the system's supervisor dispatcher automatically fails over to the other cloud providers in order (`gemini` -> `haiku`).

### `GEMINI_MODEL`
* **Default**: `gemini-3.1-flash-lite`
* **Description**: The model model identifier sent to Google AI Studio when using `DIRECTOR_PROVIDER=gemini`.

### `SCENE_WINDOW`
* **Default**: `5`
* **Description**: The number of preceding lyric lines kept in the multi-turn Ollama/Gemini conversation history. This prevents prompt poisoning on extremely long songs, while maintaining enough local context to build on the established scene.

### `STYLE_REFRESH_EVERY`
* **Default**: `4`
* **Description**: Frequency of style recovery passes. After this many consecutive frames of accumulative image-to-image, the backend triggers a style pass to re-harmonize image seams and pull drifting colors back to the artist's original technique without erasing elements.

### `STYLE_ANCHOR`
* **Default**: `(off)`
* **Supported Options**:
  * `(off)` or `none`: No recurring style string is appended. Keeps the image generation extremely free and dynamic.
  * `first`: Extracts the first comma-clause of the initial style chosen by the artist and appends it to every generated prompt to anchor the style.
  * *[Custom String]* (e.g., `flat painted illustration`): Directly appends this descriptor to the end of every single prompt generated by the Director.

### `DIRECTOR_MIN_INTERVAL_MS`
* **Default**: `0` (when live) or `3000` (when in `replay` mode)
* **Description**: An artificial pacing gate (minimum time) between consecutive Director prompts. If set to a positive value (e.g., `2500`), it prevents a fast speech stream from generating new images too quickly, allowing the screen to hold each visual frame for a comfortable duration. In replay mode, this gate is automatically scaled by `REPLAY_SPEED`.

---

## 🎨 4. Image Generation Providers & Canvas Modes

Controls how and where the drawings are rendered, and whether we accumulate elements on a single canvas.

### `IMAGE_PROVIDER`
* **Default**: `fal`
* **Supported Options**:
  * `fal`: Cloud-based fal.ai. Uses Flux Schnell for the first bootstrap frame, and Flux Dev for subsequent accumulative img2img frames (~1s latency).
  * `local_sdxl`: Zero-cost, completely offline SDXL Turbo sidecar running locally on your Apple Silicon GPU (~700ms latency). Compatible with fal.ai API structure.
  * `google`: Google Imagen 4 Fast via API.
  * `pollinations`: Pollinations.ai (Flux, free, no keys, but higher latencies and no state cache).
  * `cloudflare`: Cloudflare Workers AI SDXL img2img pipeline (very low cost alternative).

### `IMAGE_MODE`
* **Default**: `story`
* **Supported Options**:
  * `story`: **Accumulative image-to-image.** The core experience. Every frame uses the previous image as an input, building on top of it.
  * `classic`: **Independent text-to-image.** Generates a completely separate, fresh image for every committed lyric line. No visual accumulation.

### `RENDER_MODE`
* **Default**: `img2img`
* **Supported Options**:
  * `img2img`: Uses image-to-image transitions.
  * `txt2img`: Forces pure text-to-image generations even in story mode.

### `COMPOSE_MODE`
* **Default**: `inpaint`
* **Supported Options**:
  * `inpaint`: **Grid-based ellipse inpainting.** When the Director adds a lyric element, the backend calculates one of the 9 grid positions, soft-masks that coordinate, and in-paints only that ellipse. This guarantees text/element legibility because the model focuses purely on that element inside the mask, leaving the rest of the canvas completely untouched.
  * `global`: Traditional whole-canvas img2img. The entire image undergoes a low-strength denoising pass. Elements are less localized but the scene is more unified.

### `LOCAL_MORPH`
* **Default**: `true`
* **Description**: Boolean toggle (`true` \| `1` \| `yes` \| `false`). If enabled, when using `IMAGE_PROVIDER=local_sdxl`, the backend requests and receives intermediate **latent slerp morph frames** along with the final image. This enables smooth generative stop-motion morphs (rather than plain opacity crossfades) on the browser screen.

### `COMPOSE_ATMOS_STRENGTH`
* **Default**: `0.4`
* **Range**: `0.0` - `1.0`
* **Description**: The denoising strength applied during "atmospheric" whole-canvas style passes. These passes run periodically (`STYLE_REFRESH_EVERY`) or when there are no specific elements to inpaint. It is intentionally kept low (`0.4`) so that the re-styling pass harmonizes the canvas without re-synthesizing and erasing previously inpainted elements.

---

## ⚡ 5. Local SDXL Turbo Sidecar Parameters

These parameters run inside the Python `local-sdxl` sidecar server (`local-sdxl/server.py`) to manage local VRAM allocation, PyTorch MPS hardware acceleration, and the inpaint/slerp pipelines.

### 📦 Host & Port Settings
* **`BIND_HOST`** (Default: `127.0.0.1`): Host address the FastAPI sidecar server binds to.
* **`BIND_PORT`** (Default: `8003`): Port the sidecar listens on.
* **`PUBLIC_HOST`** (Default: Same as `BIND_HOST`): Hostname embedded in returned image and morph frame URLs.
* **`SDXL_CACHE_DIR`** (Default: `/tmp/local_sdxl_cache`): Disk location where generated PNGs and morph JPEGs are stored and cached.

### 🧠 Model & Hardware Options
* **`SDXL_MODEL`** (Default: `stabilityai/sdxl-turbo`): HuggingFace Diffusers repo to load.
* **`SDXL_DEVICE`** (Default: `mps`): Target computing device.
  * `mps`: Apple Silicon Metal Performance Shaders (M1/M2/M3/M4 GPUs).
  * `cuda`: NVIDIA GPU.
  * `cpu`: Standard CPU fallback (too slow for live stage shows).
* **`USE_TINY_VAE`** (Default: `1`): Set to `1` to enable TAESD (Tiny AutoEncoder for Stable Diffusion). Decodes latents **5-10x faster** than the full VAE with a negligible quality loss, critical for keeping real-time morph generation under 200ms. Set to `0` to fall back to the full-size SDXL VAE.

### 🎨 Generation & Transition Knobs
* **`SDXL_WIDTH`** (Default: `1024`): Rendered width in pixels.
* **`SDXL_HEIGHT`** (Default: `576`): Rendered height (keeps a 16:9 widescreen ratio suited for stage screens/televisions).
* **`SDXL_STRENGTH`** (Default: `0.78`): The main strength lever for global img2img.
  * *Higher (0.8+)*: Rapidly evolves the scene, but risks losing structural continuity.
  * *Lower (0.5-0.6)*: High continuity, but elements may feel "stuck" or fail to change between frames.
* **`SDXL_STEPS`** (Default: `3`): Number of scheduler steps. SDXL Turbo sweet spot is `1` to `4`. Note that the actual running steps = `int(SDXL_STEPS * SDXL_STRENGTH)`. With `STEPS=3` and `STRENGTH=0.78`, the model performs exactly `2` real denoising steps.
* **`MORPH_FRAMES`** (Default: `5`): The number of intermediate latent-space slerp (spherical linear interpolation) frames generated between the previous image's latents and the new image's latents. Setting to `0` disables morph generation completely.

### 🎭 Inpainting, Masking & Cam Zoom
* **`INPAINT_STRENGTH`** (Default: `0.95`): The denoising strength inside the active ellipse mask. Kept near `1.0` to force fresh, high-contrast, recognizable objects to render within the mask.
* **`INPAINT_STEPS`** (Default: `5`): Scheduler steps used during inpainting.
* **`MASK_FEATHER_PX`** (Default: `24`): The gaussian blur radius applied to the ellipse mask edge. Feathers the transition area so inpainted elements blend seamlessly into the background without leaving sharp oval outlines.
* **`ELLIPSE_RX`** (Default: `0.22`): Horizontal radius of the element inpaint ellipse (expressed as a fraction of full canvas width, e.g., 22%).
* **`ELLIPSE_RY`** (Default: `0.28`): Vertical radius of the inpaint ellipse (expressed as a fraction of canvas height, e.g., 28%).
* **`CAMERA_ZOOM_RATE`** (Default: `0.05`): Scale change applied to the canvas per frame when camera zoom is active (`zoom = ±1`).
* **`CAMERA_PAN_RATE`** (Default: `0.05`): Fraction of canvas width/height panned per frame when camera panning is active.
* **`STYLE_PASS_STRENGTH`** (Default: `0.5`): Strength of style recovery pass.
* **`STYLE_PASS_STEPS`** (Default: `6`): Steps for style recovery.

---

## 🌥️ 6. Cloudflare Workers AI Knobs
These variables are referenced only when `IMAGE_PROVIDER=cloudflare` is set:

* **`CLOUDFLARE_ACCOUNT_ID`**: Your Cloudflare dashboard account ID.
* **`CLOUDFLARE_API_TOKEN`**: Workers AI API authorization token.
* **`CLOUDFLARE_IMG2IMG_MODEL`** (Default: `@cf/runwayml/stable-diffusion-v1-5-img2img`): Target model hosted on Cloudflare Workers AI.
* **`CLOUDFLARE_STRENGTH`** (Default: `0.7`): Strength value passed to Cloudflare's img2img pipeline.
* **`CLOUDFLARE_STEPS`** (Default: `20`): Denoising steps.
* **`CLOUDFLARE_GUIDANCE`** (Default: `7.5`): Classifier-Free Guidance (CFG) scale.

---

## 🎛️ 7. Local Whisper Sidecar Parameters

These parameters control the Python streaming Whisper WebSocket sidecar server (`local-whisper/server.py`).

* **`BIND_HOST`** (Default: `127.0.0.1`): Address the FastAPI sidecar server binds to.
* **`BIND_PORT`** (Default: `8002`): WebSocket port the sidecar listens on.
* **`WHISPER_MODEL`** (Default: `mlx-community/whisper-small-mlx-q4`): HuggingFace MLX community repo identifier. We highly recommend a 4-bit quantized (`-q4`) model to fit comfortably alongside Gemma/SDXL inside 16GB VRAM.
* **`WHISPER_LANGUAGE`** (Default: _Unset - Auto-detect_): Force a specific language (e.g. `pt`, `en`, `fr`) to bypass auto-detection and save first-segment latency.
* **`MIN_DETECT_SECS`** (Default: `1.5`): Minimum accumulated audio duration required before Whisper trusts auto-detect. Prevents incorrect auto-detection on initial short or noisy utterances.
* **`INTERIM_INTERVAL_MS`** (Default: `1200`): Frequency in milliseconds of intermediate "partial" transcription broadcasts.
* **`VAD_SILENCE_MS`** (Default: `650`): Trailing silence required in the audio stream before the sidecar considers a segment finished and commits it as final.
* **`MIN_SPEECH_MS`** (Default: `300`): Voice Activity Detection floor. Prevents background noise, mouse clicks, or short breaths from firing the transcriber.
* **`MAX_BUFFER_SECS`** (Default: `20`): Absolute safety cap on the raw audio buffer. If exceeded without VAD silence, the buffer is hard-reset to avoid infinite growth and buffer lag.

---

## 📼 8. Replay & Video Compilation Parameters

These variables control the Elixir Mix Task `mix sinestesia.replay` used to headlessly replay sessions and compile synchronized videos.

* **`REPLAY_FILE`**: Path to the session JSON file being simulated.
* **`REPLAY_SPEED`** (Default: `1.0`): Speed multiplier (e.g., `20.0` to speed up generation).
* **`REPLAY_PORT`** (Default: `4999`): Port on which the replay server hosts the mock audio sockets and serves compiled media.

---

## 🛠️ 9. Performance tuning & VRAM Guidelines

If you are running the **fully local stack** (Director via Ollama + local-whisper sidecar + local-sdxl sidecar) on a single Apple Silicon machine, memory allocation is critical:

| Hardware Configuration | Recommended Settings | VRAM Profile | Experience |
| :--- | :--- | :--- | :--- |
| **8 GB Unified Memory** | Local models will swap/thrash. Use Cloud providers:<br>`IMAGE_PROVIDER=fal`<br>`DIRECTOR_PROVIDER=gemini` | < 1 GB local | Smooth & cloud-bound |
| **16 GB Unified Memory**<br>*(M1/M2/M3/M4)* | `OLLAMA_MODEL=gemma4:9b-mlx` (or 2B)<br>`WHISPER_MODEL=mlx-community/whisper-tiny-mlx-q4`<br>`IMAGE_PROVIDER=local_sdxl`<br>`SDXL_WIDTH=768 SDXL_HEIGHT=432` | ~11-13 GB | Decent fully offline performance |
| **32 GB+ Unified Memory** | `OLLAMA_MODEL=gemma4:12b-mlx`<br>`WHISPER_MODEL=mlx-community/whisper-small-mlx-q4`<br>`IMAGE_PROVIDER=local_sdxl`<br>`SDXL_WIDTH=1024 SDXL_HEIGHT=576` | ~18-22 GB | **Premium Stage Setup.** Perfect offline latency & crisp resolution. |
