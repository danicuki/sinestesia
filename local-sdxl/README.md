# local-sdxl

HTTP sidecar exposing **SDXL Turbo image-to-image** on Apple Silicon, with
a request/response shape compatible with fal.ai's
`fal-ai/flux/dev/image-to-image` endpoint. Lets the Sinestesia backend swap
its image provider from fal to localhost by changing a single env var.

- **Server**: FastAPI on `http://127.0.0.1:8003`
- **Generated images**: served back via `GET /img/{name}.png` (cached on disk)
- **Inference**: PyTorch with MPS (Metal) on M-series

## Why

- **Cost**: zero per-image vs ~$0.025 on fal.ai Flux dev (~$11 saved per 30 min show).
- **Offline**: stage doesn't need internet for visuals.
- **Latency**: ~700-900 ms warm on M4 Max (vs ~1.5 s on fal warm).
- **Control**: future LoRA fine-tuning for the sketch aesthetic happens here.

## Hardware

Designed for Apple Silicon (M-series, 16 GB+ unified memory). SDXL Turbo in
fp16 occupies ~10 GB during inference. M4 Max with 48 GB has plenty of headroom
to run alongside Whisper medium and Gemma 12B simultaneously.

On Linux + CUDA, set `SDXL_DEVICE=cuda`. On Intel Mac or no-GPU box, set
`SDXL_DEVICE=cpu` — but it'll be too slow for live use.

## Setup

```bash
cd local-sdxl
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

If Python 3.9 complains, use [uv](https://docs.astral.sh/uv/) for a clean 3.11:

```bash
brew install uv
uv venv --python 3.11
source .venv/bin/activate
uv pip install -r requirements.txt
```

## Run

```bash
python3 server.py
```

First boot downloads the SDXL Turbo weights (~7 GB) from HuggingFace into
`~/.cache/huggingface/`. Subsequent boots are fast.

You should see:

```
[INFO] loading stabilityai/sdxl-turbo on mps (torch.float16) — this is slow the first time
[INFO] pipeline ready
INFO:     Uvicorn running on http://127.0.0.1:8003
```

Smoke test:

```bash
curl -s http://127.0.0.1:8003/healthz
# {"ok":true,"model":"stabilityai/sdxl-turbo","device":"mps"}
```

## Configuration (env vars)

| Var | Default | Notes |
|---|---|---|
| `SDXL_MODEL` | `stabilityai/sdxl-turbo` | any diffusers img2img-compatible repo |
| `SDXL_DEVICE` | `mps` | `mps` \| `cuda` \| `cpu` |
| `SDXL_STEPS` | `3` | SDXL Turbo: 1-4 sweet spot |
| `SDXL_STRENGTH` | `0.78` | higher = more change per frame, less continuity |
| `SDXL_WIDTH` | `768` | output width (kept 16:9 for stage) |
| `SDXL_HEIGHT` | `432` | output height |
| `MORPH_FRAMES` | `5` | intermediate latent-morph frames per generation; `0` disables |
| `CAMERA_ZOOM_RATE` | `0.05` | zoom scale change per frame at full deflection (`camera.zoom = ±1`) |
| `CAMERA_PAN_RATE` | `0.05` | fraction of the frame panned per frame at full deflection |
| `INPAINT_STRENGTH` | `0.95` | how fresh the masked region is in element-inpaint requests |
| `INPAINT_STEPS` | `5` | scheduler steps for inpaint (real = `int(steps*strength)`) |
| `MASK_FEATHER_PX` | `24` | gaussian blur on the placement mask edge |
| `ELLIPSE_RX` | `0.22` | element-region half-width (fraction of frame width) |
| `ELLIPSE_RY` | `0.28` | element-region half-height (fraction of frame height) |
| `STYLE_PASS_STRENGTH` | `0.35` | strength of the chained whole-canvas re-style when the request carries `style_pass` |
| `BIND_HOST` | `127.0.0.1` | bind address |
| `BIND_PORT` | `8003` | bind port |
| `PUBLIC_HOST` | _same as BIND_HOST_ | hostname embedded in returned image URLs |
| `SDXL_CACHE_DIR` | `/tmp/local_sdxl_cache` | where generated images live |

### Element inpainting (compose mode)

When the request carries `element` + `placement` (one of the nine grid
positions `top-left … bottom-right`), the server repaints ONLY a soft ellipse
at that placement, with `element` as the entire prompt. This is how lyric
elements are guaranteed to materialize: inside the mask the model is in its
single-subject regime and the text is the only content signal, while the rest
of the canvas is untouched by construction. Requests without `element` behave
as before (whole-canvas img2img).

The inpaint prompt is biased with ", large, bold and prominent, filling the
frame" — without it the model paints "a scene containing a small X" inside the
ellipse and elements read as details on a stage screen.

When a request carries `style_pass` (text), a gentle whole-canvas img2img with
that text as the prompt is chained AFTER the main op (`STYLE_PASS_STRENGTH`).
The backend sends it every `STYLE_REFRESH_EVERY` images as style recovery: it
pulls a drifting canvas back to the look and harmonizes inpaint seams without
erasing the accumulated composition.

## API

### POST /generate

Request body matches the subset of fal.ai's flux/dev/image-to-image that the
backend actually sends:

```json
{
  "prompt": "A hand-drawn scene showing a sun, a castle, and a glove. loose ink sketch on aged paper.",
  "image_url": "https://fal.media/files/elephant/abc.jpg",
  "strength": 0.55,
  "num_inference_steps": 2,
  "image_size": "landscape_16_9"
}
```

`image_url` can be:
- A public HTTPS URL (fal CDN, etc.)
- A `http://localhost:8003/img/...` URL (when chaining img2img calls)
- A `data:image/png;base64,...` data URL

Response:

```json
{
  "images": [
    {"url": "http://127.0.0.1:8003/img/<uuid>.png", "width": 768, "height": 432}
  ],
  "frames": [
    "http://127.0.0.1:8003/img/<uuid>_m1.jpg",
    "http://127.0.0.1:8003/img/<uuid>_m2.jpg",
    "http://127.0.0.1:8003/img/<uuid>.png"
  ],
  "timings": {"fetch_ms": 0, "infer_ms": 720, "morph_ms": 240, "input_source": "latent-cache"}
}
```

`frames` is the **latent-space morph**: `MORPH_FRAMES` intermediates obtained by
slerp between the previous frame's latents and the new ones, decoded with the
tiny VAE, ending on the final image. Each intermediate is a real decoded image
(a generative morph, not a pixel crossfade). The frontend plays the sequence as
a chained morph; ignoring it and using `images[0]` still works.

### Latent cache

The output latents of recent generations are kept in memory keyed by filename.
When the backend chains img2img on one of our own `/img/...` URLs (the normal
story-mode loop), the server feeds the cached latents straight back into the
pipeline. This skips the HTTP self-fetch and the VAE re-encode (~100-180ms
saved per frame) and — more importantly — avoids the generational
decode→encode loss that slowly blurs the canvas over a long song.
`timings.input_source` reports which path was taken: `latent-cache`, `disk`
(file read, no HTTP), or `http`.

### GET /img/{name}

Serves a previously generated image by filename. Used by:
1. The browser to render visuals (the URL handed back via the WebSocket).
2. Subsequent `/generate` calls to chain img2img on the previous frame.

## Wire into Sinestesia backend

```
# backend/.env
IMAGE_PROVIDER=local_sdxl
LOCAL_SDXL_URL=http://127.0.0.1:8003
```

See `backend/lib/sinestesia/image_gen/local_sdxl.ex`.

## Tuning

### Latency too high?

- Drop `SDXL_STEPS=1` (rougher visuals, ~half the latency).
- Drop resolution: `SDXL_WIDTH=768 SDXL_HEIGHT=432`.
- Skip the fetch round-trip by sending base64 data URLs from the backend
  when chaining img2img on a recent local generation.

### Frames change TOO LITTLE between images (look "stuck")?

This is the most common SDXL-Turbo-vs-Flux surprise. Two causes:
- **Strength too low**: raise `SDXL_STRENGTH` toward 0.8. Strength sets how
  much noise is injected into the previous frame — it's the main lever for
  "amount of change".
- **Too few real denoising steps**: `real_steps = int(SDXL_STEPS * SDXL_STRENGTH)`.
  With steps=2, strength=0.55 that's only 1 step → barely any change. Keep
  `SDXL_STEPS` at 3-4 so a couple of real steps run.

### Frames change TOO MUCH (lose continuity, feel random)?

- Lower `SDXL_STRENGTH` toward 0.5. Lower = more of the previous frame survives.

### Custom sketch style without prompt engineering?

- Train a LoRA on 50-100 sketch images and load it via `pipe.load_lora_weights(...)`.
  Future enhancement; not in v1.
