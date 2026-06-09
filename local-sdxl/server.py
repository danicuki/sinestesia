"""
Local SDXL Turbo image-to-image HTTP server for Sinestesia.

Drop-in replacement for fal.ai Flux dev img2img. Speaks the same request /
response shape so the Elixir backend only needs to swap `IMAGE_PROVIDER`
and `LOCAL_SDXL_URL` to point here instead of `fal.run/...`.

Endpoints
---------
POST /generate                — fal-compatible img2img
GET  /img/{name}              — serves generated PNGs back to the browser
GET  /healthz                 — quick liveness ping

Request body (POST /generate)
-----------------------------
{
  "prompt": "A hand-drawn scene showing ...",
  "image_url": "https://fal.media/.../abc.jpg",   // OR http://localhost OR data:image/...
  "strength": 0.55,                                // optional
  "num_inference_steps": 2,                        // optional (SDXL Turbo: 1-4)
  "image_size": "landscape_16_9"                   // optional (kept for fal parity)
}

Response
--------
{
  "images": [{"url": "http://127.0.0.1:8003/img/<uuid>.png", "width": 1024, "height": 576}],
  "timings": {"infer_ms": 720, "fetch_ms": 80}
}
"""

from __future__ import annotations

import asyncio
import base64
import io
import logging
import os
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional

import requests
import torch
from PIL import Image
from diffusers import AutoPipelineForImage2Image
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("local-sdxl")

# ──────────────────────────────────────────────────────────────────────────────
# Config (env-overridable)
# ──────────────────────────────────────────────────────────────────────────────

MODEL_ID = os.environ.get("SDXL_MODEL", "stabilityai/sdxl-turbo")
DEVICE = os.environ.get("SDXL_DEVICE", "mps")  # mps | cuda | cpu
DTYPE = torch.float16 if DEVICE in ("mps", "cuda") else torch.float32
BIND_HOST = os.environ.get("BIND_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("BIND_PORT", "8003"))
PUBLIC_HOST = os.environ.get("PUBLIC_HOST", BIND_HOST)  # what URL we hand back

# SDXL Turbo was trained at 512x512. 768x432 is a good 16:9 compromise: noticeably
# faster than 1024 (inference time scales ~quadratically with pixel count) while
# still sharp enough for a stage projection, especially with the sketch aesthetic
# and crossfade transitions softening everything. Drop to 512x288 for ~2x more speed.
DEFAULT_WIDTH = int(os.environ.get("SDXL_WIDTH", "768"))
DEFAULT_HEIGHT = int(os.environ.get("SDXL_HEIGHT", "432"))

# TAESD: a tiny distilled VAE that decodes latents ~5-10x faster than the full
# SDXL VAE, with a small quality cost that's invisible for the sketch look.
# Set USE_TINY_VAE=0 to fall back to the full VAE.
USE_TINY_VAE = os.environ.get("USE_TINY_VAE", "1") not in ("0", "false", "no")
# steps=3, strength=0.78 → int(3*0.78)=2 real denoising steps, with enough
# injected noise that each frame visibly evolves (matching how fal's Flux
# img2img at strength 0.8 looked). Lower strength → frames look more "stuck".
DEFAULT_STEPS = int(os.environ.get("SDXL_STEPS", "3"))
DEFAULT_STRENGTH = float(os.environ.get("SDXL_STRENGTH", "0.78"))

# Cache dir for generated images we serve via /img/{name}.
CACHE_DIR = Path(os.environ.get("SDXL_CACHE_DIR", "/tmp/local_sdxl_cache"))
CACHE_DIR.mkdir(parents=True, exist_ok=True)

# ──────────────────────────────────────────────────────────────────────────────


class GenerateRequest(BaseModel):
    prompt: str
    image_url: Optional[str] = None
    strength: Optional[float] = None
    num_inference_steps: Optional[int] = None
    image_size: Optional[str] = None  # kept for fal parity, ignored for now
    # Below are accepted but ignored — fal sends them, we don't need them.
    enable_safety_checker: Optional[bool] = None


app = FastAPI()

# Three.js TextureLoader requires CORS headers to use the image as a WebGL
# texture. Without these the image fetches successfully (HTTP 200) but the
# WebGL texture upload silently fails — symptom: only the first frame ever
# shows on stage. Allow all origins since this server only binds localhost.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)

pipe: Optional[AutoPipelineForImage2Image] = None
executor = ThreadPoolExecutor(max_workers=1)  # serialize GPU access


def load_pipeline():
    log.info("loading %s on %s (%s) — this is slow the first time", MODEL_ID, DEVICE, DTYPE)
    p = AutoPipelineForImage2Image.from_pretrained(
        MODEL_ID,
        torch_dtype=DTYPE,
        variant="fp16" if DTYPE == torch.float16 else None,
        use_safetensors=True,
    )

    if USE_TINY_VAE:
        from diffusers import AutoencoderTiny

        log.info("swapping in TAESD tiny VAE for faster decode")
        p.vae = AutoencoderTiny.from_pretrained(
            "madebyollin/taesdxl", torch_dtype=DTYPE
        )

    p = p.to(DEVICE)
    # SDXL Turbo doesn't use classifier-free guidance, so the negative-prompt
    # path is dead weight. Disabling it saves a chunk of memory + a hair of latency.
    if hasattr(p, "set_progress_bar_config"):
        p.set_progress_bar_config(disable=True)
    log.info("pipeline ready")
    return p


def fetch_input_image(image_url: str) -> Image.Image:
    """Accept https URL, http://localhost URL, or `data:image/...;base64,...`."""
    if image_url.startswith("data:"):
        _, _, payload = image_url.partition(",")
        raw = base64.b64decode(payload)
        return Image.open(io.BytesIO(raw)).convert("RGB")

    # Network fetch (fal CDN or our own /img/ URL on repeat calls).
    resp = requests.get(image_url, timeout=15)
    resp.raise_for_status()
    return Image.open(io.BytesIO(resp.content)).convert("RGB")


def fit_clip_prompt(prompt: str) -> str:
    """SDXL's CLIP text encoders cap at 77 tokens. The Director's accumulative
    prompt grows past that as the scene fills up, and CLIP truncates the TAIL —
    which is exactly where the newest element and the style note live, so the
    new element would never get drawn.

    We instead keep the TAIL and drop the oldest elements from the text. Those
    old elements still persist visually through img2img chaining, so dropping
    them from the prompt costs nothing while guaranteeing the new element +
    style note always survive."""
    tok = pipe.tokenizer
    ids = tok(prompt, truncation=False, add_special_tokens=False)["input_ids"]
    limit = 75  # leave headroom for BOS/EOS
    if len(ids) <= limit:
        return prompt
    fitted = tok.decode(ids[-limit:]).strip()
    return fitted


def run_inference(prompt: str, init_image: Image.Image, strength: float, steps: int) -> Image.Image:
    width, height = DEFAULT_WIDTH, DEFAULT_HEIGHT
    init_image = init_image.resize((width, height), Image.LANCZOS)
    prompt = fit_clip_prompt(prompt)

    # In diffusers img2img the actual denoising work is:
    #   real_steps = int(num_inference_steps * strength)
    # and `strength` ALSO sets how much noise is added to the input — higher
    # strength = more deviation from the previous frame (more visible change).
    #
    # If real_steps rounds to 0 nothing happens, so bump steps to guarantee
    # at least one denoising step. (SDXL Turbo: guidance_scale must be 0.)
    if int(steps * strength) < 1:
        steps = max(int(round(1.0 / max(strength, 0.05))), 1)

    result = pipe(
        prompt=prompt,
        image=init_image,
        strength=strength,
        num_inference_steps=steps,
        guidance_scale=0.0,
        width=width,
        height=height,
    )
    return result.images[0]


@app.on_event("startup")
async def startup():
    global pipe
    pipe = load_pipeline()


@app.get("/healthz")
async def healthz():
    return {"ok": pipe is not None, "model": MODEL_ID, "device": DEVICE}


@app.get("/img/{name}")
async def get_img(name: str):
    path = CACHE_DIR / name
    if not path.exists():
        raise HTTPException(404)
    return FileResponse(path, media_type="image/png")


@app.post("/generate")
async def generate(req: GenerateRequest):
    if pipe is None:
        raise HTTPException(503, "pipeline not ready")
    if not req.image_url:
        # In img2img mode we always need an input image. For a true t2i mode
        # we'd swap to AutoPipelineForText2Image — out of scope for v1.
        raise HTTPException(400, "image_url is required (this server is img2img only)")

    t0 = time.monotonic()
    try:
        init = await asyncio.get_event_loop().run_in_executor(
            executor, fetch_input_image, req.image_url
        )
    except Exception as e:
        log.exception("input image fetch failed")
        raise HTTPException(400, f"fetch failed: {e}")
    fetch_ms = int((time.monotonic() - t0) * 1000)

    strength = req.strength if req.strength is not None else DEFAULT_STRENGTH
    steps = req.num_inference_steps if req.num_inference_steps is not None else DEFAULT_STEPS

    t1 = time.monotonic()
    out = await asyncio.get_event_loop().run_in_executor(
        executor, run_inference, req.prompt, init, strength, steps
    )
    infer_ms = int((time.monotonic() - t1) * 1000)

    name = f"{uuid.uuid4().hex}.png"
    out_path = CACHE_DIR / name
    out.save(out_path, "PNG", optimize=False)

    public_url = f"http://{PUBLIC_HOST}:{BIND_PORT}/img/{name}"
    log.info("generated %s (fetch %dms, infer %dms)", name, fetch_ms, infer_ms)

    return JSONResponse(
        {
            "images": [
                {"url": public_url, "width": out.width, "height": out.height}
            ],
            "timings": {"fetch_ms": fetch_ms, "infer_ms": infer_ms},
        }
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "server:app",
        host=BIND_HOST,
        port=BIND_PORT,
        log_level="info",
        reload=False,
    )
