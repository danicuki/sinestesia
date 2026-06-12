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
  "frames": ["http://.../img/<uuid>_m1.jpg", ..., "http://.../img/<uuid>.png"],
  "timings": {"infer_ms": 720, "fetch_ms": 80, "morph_ms": 240}
}

`frames` is the latent-space morph sequence from the previous image to the new
one (slerp in latent space, decoded with the tiny VAE), ending on the final
image. The frontend plays it as a continuous morph; clients that ignore it
fall back to the single `images[0]` crossfade.
"""

from __future__ import annotations

import asyncio
import base64
import io
import logging
import os
import re
import time
import uuid
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional, Tuple

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
DEFAULT_WIDTH = int(os.environ.get("SDXL_WIDTH", "512"))
DEFAULT_HEIGHT = int(os.environ.get("SDXL_HEIGHT", "288"))

# TAESD: a tiny distilled VAE that decodes latents ~5-10x faster than the full
# SDXL VAE, with a small quality cost that's invisible for the sketch look.
# Set USE_TINY_VAE=0 to fall back to the full VAE.
USE_TINY_VAE = os.environ.get("USE_TINY_VAE", "1") not in ("0", "false", "no")
# steps=3, strength=0.78 → int(3*0.78)=2 real denoising steps, with enough
# injected noise that each frame visibly evolves (matching how fal's Flux
# img2img at strength 0.8 looked). Lower strength → frames look more "stuck".
DEFAULT_STEPS = int(os.environ.get("SDXL_STEPS", "3"))
DEFAULT_STRENGTH = float(os.environ.get("SDXL_STRENGTH", "0.78"))

# Morph: number of INTERMEDIATE frames decoded between the previous image and
# the new one (slerp in latent space). Each one costs a TAESD decode + JPEG
# save (~50-70ms on M4 Max), all after the final image is already saved, so it
# delays nothing the audience is waiting on. 0 disables morphing.
MORPH_FRAMES = int(os.environ.get("MORPH_FRAMES", "5"))

# Camera: per-frame movement rates at FULL deflection (camera values are
# -1..1, sent by the operator through the backend). Zoom rate is the scale
# change per generated frame; pan rate is the fraction of the frame width/
# height traveled per generated frame. The revealed band at the edges is
# border-padded latents that the denoiser repaints under the current prompt —
# which is exactly where new elements tend to appear, like a cameraman opening
# space for the scene to grow.
CAMERA_ZOOM_RATE = float(os.environ.get("CAMERA_ZOOM_RATE", "0.05"))
CAMERA_PAN_RATE = float(os.environ.get("CAMERA_PAN_RATE", "0.05"))

# Cache dir for generated images we serve via /img/{name}.
CACHE_DIR = Path(os.environ.get("SDXL_CACHE_DIR", "/tmp/local_sdxl_cache"))
CACHE_DIR.mkdir(parents=True, exist_ok=True)

# Output latents of recent generations, keyed by served image filename. When
# the backend chains img2img on one of our own /img/ URLs we feed these straight
# back into the pipeline, skipping the HTTP self-fetch AND the VAE re-encode —
# and, more importantly, avoiding the generational decode→encode loss that
# slowly degrades the canvas over a long song. ~83KB per entry at 768x432 fp16.
LATENT_CACHE_MAX = 16
latent_cache: "OrderedDict[str, torch.Tensor]" = OrderedDict()

IMG_URL_RE = re.compile(r"/img/([A-Za-z0-9_.-]+)$")

# ──────────────────────────────────────────────────────────────────────────────


# Inpaint compositing: how hard the masked region is re-noised (≈1.0 = fully
# fresh content inside the mask) and how many scheduler steps to request
# (real steps = int(steps * strength)).
INPAINT_STRENGTH = float(os.environ.get("INPAINT_STRENGTH", "0.95"))
INPAINT_STEPS = int(os.environ.get("INPAINT_STEPS", "5"))
# Style consolidation pass (`style_pass` in the request): a gentle whole-canvas
# img2img with the style note as the prompt, chained AFTER the main op. Strong
# enough to pull a drifting canvas back to the look and harmonize inpaint
# seams, weak enough to keep the accumulated composition.
STYLE_PASS_STRENGTH = float(os.environ.get("STYLE_PASS_STRENGTH", "0.35"))
# Soft edge so the new element blends into the canvas instead of showing a
# hard ellipse seam, in pixels of gaussian blur on the mask.
MASK_FEATHER_PX = int(os.environ.get("MASK_FEATHER_PX", "24"))

# 3x3 placement grid → ellipse center (fractions of width/height). Centers
# are pulled slightly inward so the larger ellipse stays mostly on-canvas.
PLACEMENTS = {
    "top-left": (0.25, 0.28),
    "top": (0.50, 0.26),
    "top-right": (0.75, 0.28),
    "left": (0.25, 0.52),
    "center": (0.50, 0.50),
    "right": (0.75, 0.52),
    "bottom-left": (0.25, 0.74),
    "bottom": (0.50, 0.76),
    "bottom-right": (0.75, 0.74),
}
# Element region size (~19% of the frame). Element visibility comes mostly
# from the "filling the frame" prompt bias, not from mask area: at 0.27/0.34
# (~29%) each inpaint repainted nearly a third of the canvas and wrecked the
# accumulated scene; at 0.20/0.26 (~16%) elements read as details on stage.
ELLIPSE_RX = float(os.environ.get("ELLIPSE_RX", "0.22"))  # fraction of width
ELLIPSE_RY = float(os.environ.get("ELLIPSE_RY", "0.28"))  # fraction of height


class CameraState(BaseModel):
    """Operator-driven virtual camera, all values -1..1 (0 = still).
    zoom > 0 zooms in; zoom < 0 zooms out (scene recedes, edges open up).
    pan_x > 0 pans the camera right (scene slides left); pan_y > 0 pans up."""
    zoom: float = 0.0
    pan_x: float = 0.0
    pan_y: float = 0.0

    def is_neutral(self) -> bool:
        return self.zoom == 0.0 and self.pan_x == 0.0 and self.pan_y == 0.0


class GenerateRequest(BaseModel):
    prompt: str
    image_url: Optional[str] = None
    strength: Optional[float] = None
    num_inference_steps: Optional[int] = None
    image_size: Optional[str] = None  # kept for fal parity, ignored for now
    camera: Optional[CameraState] = None
    # Compositing mode: when `element` is present the request is an INPAINT —
    # only the soft-masked region at `placement` is re-denoised, with `element`
    # as the whole prompt (single-subject regime, where Turbo's CFG-free
    # conditioning actually obeys the text). The rest of the canvas is
    # untouched by construction. `placement` is one of the PLACEMENTS keys.
    element: Optional[str] = None
    placement: Optional[str] = None
    # When present, a gentle whole-canvas img2img pass with this text as the
    # prompt runs AFTER the main op (periodic style recovery, see
    # STYLE_PASS_STRENGTH).
    style_pass: Optional[str] = None
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
ipipe = None  # AutoPipelineForInpainting sharing the same weights (from_pipe)
tpipe = None  # AutoPipelineForText2Image sharing the same weights (from_pipe)
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


# ── Latent-space plumbing ─────────────────────────────────────────────────────
#
# The pipeline accepts a 4-channel tensor as `image` (diffusers passes latents
# through preprocess/prepare_latents untouched) and returns un-decoded latents
# with output_type="latent". We exploit both: stay in latent space across the
# whole img2img chain, decode to pixels only for serving.


def _latent_scale_shift() -> Tuple[float, Optional[torch.Tensor], Optional[torch.Tensor]]:
    cfg = pipe.vae.config
    mean = getattr(cfg, "latents_mean", None)
    std = getattr(cfg, "latents_std", None)
    if mean is not None and std is not None:
        mean = torch.tensor(mean).view(1, 4, 1, 1)
        std = torch.tensor(std).view(1, 4, 1, 1)
    else:
        mean = std = None
    return cfg.scaling_factor, mean, std


def encode_latents(img: Image.Image) -> torch.Tensor:
    """PIL image → latents in the pipeline's scaled latent space (the same
    space `output_type='latent'` returns, and what `image=<latents>` expects)."""
    x = pipe.image_processor.preprocess(img).to(device=DEVICE, dtype=pipe.vae.dtype)
    with torch.no_grad():
        enc = pipe.vae.encode(x)
    # AutoencoderTiny returns .latents; the full VAE returns a distribution.
    lat = enc.latents if hasattr(enc, "latents") else enc.latent_dist.sample()
    sf, mean, std = _latent_scale_shift()
    if mean is not None:
        lat = (lat - mean.to(lat)) * sf / std.to(lat)
    else:
        lat = lat * sf
    return lat.to(dtype=DTYPE)


def decode_latents(lat: torch.Tensor) -> Image.Image:
    """Scaled latents → PIL image (mirrors the pipeline's own decode path)."""
    sf, mean, std = _latent_scale_shift()
    if mean is not None:
        lat = lat * std.to(lat) / sf + mean.to(lat)
    else:
        lat = lat / sf
    with torch.no_grad():
        img = pipe.vae.decode(lat.to(dtype=pipe.vae.dtype), return_dict=False)[0]
    return pipe.image_processor.postprocess(img.detach(), output_type="pil")[0]


def slerp(a: torch.Tensor, b: torch.Tensor, t: float) -> torch.Tensor:
    """Spherical interpolation between two latent tensors. For the magnitudes
    diffusion latents live at, plain lerp washes out toward gray mid-way; slerp
    keeps the norm on the hypersphere so intermediates decode as real images."""
    a_f, b_f = a.flatten().float(), b.flatten().float()
    dot = torch.dot(a_f / a_f.norm(), b_f / b_f.norm()).clamp(-1.0, 1.0)
    if dot.abs() > 0.9995:  # near-parallel: lerp is fine and avoids div-by-~0
        return a + (b - a) * t
    omega = torch.acos(dot)
    so = torch.sin(omega)
    return (torch.sin((1.0 - t) * omega) / so) * a + (torch.sin(t * omega) / so) * b


def apply_camera(lat: torch.Tensor, cam: CameraState) -> torch.Tensor:
    """Affine camera move applied to the previous frame's latents before
    img2img. Latents are spatially coherent (8x-downsampled image), so a
    bilinear warp on them is equivalent to warping the image, without an extra
    decode/encode round-trip. Edges revealed by the move are border-padded
    smears that the denoiser repaints under the current prompt.

    Runs on CPU in float32: the tensor is tiny (1x4x54x96) and MPS support for
    grid_sample is not worth depending on."""
    import torch.nn.functional as F

    zoom = max(-1.0, min(1.0, cam.zoom))
    pan_x = max(-1.0, min(1.0, cam.pan_x))
    pan_y = max(-1.0, min(1.0, cam.pan_y))

    # Sampling scale is the inverse of the visual scale: zoom IN (scene grows)
    # = sample a smaller source window. affine_grid works in normalized [-1,1]
    # coords, so a pan of PAN_RATE (fraction of frame) is 2*PAN_RATE units.
    s = 1.0 / (1.0 + CAMERA_ZOOM_RATE * zoom)
    tx = 2.0 * CAMERA_PAN_RATE * pan_x
    # Screen y is flipped relative to "pan up": panning up shows content above,
    # i.e. samples source at smaller y.
    ty = -2.0 * CAMERA_PAN_RATE * pan_y

    theta = torch.tensor([[[s, 0.0, tx], [0.0, s, ty]]], dtype=torch.float32)
    src = lat.detach().to("cpu", torch.float32)
    grid = F.affine_grid(theta, list(src.shape), align_corners=False)
    out = F.grid_sample(src, grid, mode="bilinear", padding_mode="border", align_corners=False)
    return out.to(device=lat.device, dtype=lat.dtype)


def cache_latents(name: str, lat: torch.Tensor) -> None:
    latent_cache[name] = lat.detach()
    latent_cache.move_to_end(name)
    while len(latent_cache) > LATENT_CACHE_MAX:
        latent_cache.popitem(last=False)


def expected_latent_shape() -> Tuple[int, int, int, int]:
    return (1, 4, DEFAULT_HEIGHT // 8, DEFAULT_WIDTH // 8)


def resolve_input(image_url: str) -> Tuple[Optional[torch.Tensor], Optional[Image.Image], str]:
    """Cheapest available source for the init image, in order:
    latent cache (no fetch, no encode) → local cache dir (no fetch) → HTTP."""
    m = IMG_URL_RE.search(image_url)
    if m:
        name = m.group(1)
        lat = latent_cache.get(name)
        # Shape guard: a mid-run SDXL_WIDTH/HEIGHT change invalidates old latents.
        if lat is not None and tuple(lat.shape) == expected_latent_shape():
            return lat, None, "latent-cache"
        path = CACHE_DIR / name
        if path.exists():
            return None, Image.open(path).convert("RGB"), "disk"
    return None, fetch_input_image(image_url), "http"


def build_mask(placement: Optional[str]) -> Image.Image:
    """Soft ellipse mask (white = repaint) at one of the 3x3 grid placements."""
    from PIL import ImageDraw, ImageFilter

    cx_f, cy_f = PLACEMENTS.get(placement or "center", PLACEMENTS["center"])
    w, h = DEFAULT_WIDTH, DEFAULT_HEIGHT
    cx, cy = cx_f * w, cy_f * h
    rx, ry = ELLIPSE_RX * w, ELLIPSE_RY * h

    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=255)
    return mask.filter(ImageFilter.GaussianBlur(MASK_FEATHER_PX))


def run_job(prompt: str, image_url: Optional[str], strength: float, steps: int,
            camera: Optional[CameraState] = None,
            element: Optional[str] = None,
            placement: Optional[str] = None,
            style_pass: Optional[str] = None) -> dict:
    """The whole GPU job, serialized on the single-worker executor:
    resolve input → camera move → denoise (latents out) → save final →
    decode morph frames."""
    timings: dict = {}

    t0 = time.monotonic()
    if image_url:
        lat_in, pil_in, source = resolve_input(image_url)
        if pil_in is not None:
            pil_in = pil_in.resize((DEFAULT_WIDTH, DEFAULT_HEIGHT), Image.LANCZOS)
            lat_in = encode_latents(pil_in)
        if camera is not None and not camera.is_neutral():
            lat_in = apply_camera(lat_in, camera)
            timings["camera"] = f"z{camera.zoom:+.2f} x{camera.pan_x:+.2f} y{camera.pan_y:+.2f}"
        timings["fetch_ms"] = int((time.monotonic() - t0) * 1000)
        timings["input_source"] = source

        t1 = time.monotonic()

        if element:
            # ── Inpaint compositing: repaint ONLY the placement region with the
            # new element as the entire prompt. Decode the (possibly camera-
            # warped) input latents so the canvas the mask sits on is exactly the
            # chain state.
            canvas = decode_latents(lat_in)
            mask = build_mask(placement)
            # Without the size bias the model paints "a scene containing a small
            # X" inside the ellipse — the element ends up a detail. Bias it to
            # fill the masked region instead.
            lat_out = ipipe(
                prompt=fit_clip_prompt(f"{element}, large, bold and prominent, filling the frame"),
                image=canvas,
                mask_image=mask,
                strength=INPAINT_STRENGTH,
                num_inference_steps=INPAINT_STEPS,
                guidance_scale=0.0,
                width=DEFAULT_WIDTH,
                height=DEFAULT_HEIGHT,
                output_type="latent",
            ).images
            timings["mode"] = f"inpaint@{placement or 'center'}"
        else:
            # ── Global img2img (atmospheric shifts, classic behaviour).
            # Real denoising work is int(num_inference_steps * strength); strength
            # also sets how much noise is injected (more = more change). If the
            # product rounds to 0 nothing happens, so guarantee one step.
            # (SDXL Turbo: guidance_scale must be 0.)
            if int(steps * strength) < 1:
                steps = max(int(round(1.0 / max(strength, 0.05))), 1)

            lat_out = pipe(
                prompt=fit_clip_prompt(prompt),
                image=lat_in,
                strength=strength,
                num_inference_steps=steps,
                guidance_scale=0.0,
                output_type="latent",
            ).images
            timings["mode"] = "img2img"

        # Periodic style recovery: re-style the WHOLE canvas (inpainted element
        # included, so it harmonizes into the look) without erasing composition.
        if style_pass:
            ts = time.monotonic()
            lat_out = pipe(
                prompt=fit_clip_prompt(style_pass),
                image=lat_out,
                strength=STYLE_PASS_STRENGTH,
                num_inference_steps=5,
                guidance_scale=0.0,
                output_type="latent",
            ).images
            timings["style_pass_ms"] = int((time.monotonic() - ts) * 1000)

        timings["infer_ms"] = int((time.monotonic() - t1) * 1000)

        # Final image first, so the slowest consumer (the next img2img call and any
        # client ignoring `frames`) is unblocked as early as possible.
        final = decode_latents(lat_out)
        stem = uuid.uuid4().hex
        final_name = f"{stem}.png"
        final.save(CACHE_DIR / final_name, "PNG", optimize=False)
        cache_latents(final_name, lat_out)

        # Morph: slerp between the input and output latents, decode intermediates.
        # Consecutive frames are img2img-related so the in-betweens decode as
        # plausible images — a generative morph, not a pixel dissolve.
        t2 = time.monotonic()
        frame_names = []
        for k in range(1, MORPH_FRAMES + 1):
            t = k / (MORPH_FRAMES + 1)
            mid = decode_latents(slerp(lat_in, lat_out, t))
            name = f"{stem}_m{k}.jpg"
            mid.save(CACHE_DIR / name, "JPEG", quality=88)
            frame_names.append(name)
        frame_names.append(final_name)
        timings["morph_ms"] = int((time.monotonic() - t2) * 1000)
    else:
        # ── Text to Image (first frame / bootstrap)
        timings["fetch_ms"] = 0
        timings["input_source"] = "none"

        t1 = time.monotonic()
        # SDXL Turbo: guidance_scale must be 0
        lat_out = tpipe(
            prompt=fit_clip_prompt(prompt),
            num_inference_steps=steps,
            guidance_scale=0.0,
            width=DEFAULT_WIDTH,
            height=DEFAULT_HEIGHT,
            output_type="latent",
        ).images
        timings["mode"] = "txt2img"
        timings["infer_ms"] = int((time.monotonic() - t1) * 1000)

        final = decode_latents(lat_out)
        stem = uuid.uuid4().hex
        final_name = f"{stem}.png"
        final.save(CACHE_DIR / final_name, "PNG", optimize=False)
        cache_latents(final_name, lat_out)

        # No morph frames for the first image
        frame_names = [final_name]
        timings["morph_ms"] = 0

    return {
        "final_name": final_name,
        "frame_names": frame_names,
        "width": final.width,
        "height": final.height,
        "timings": timings,
    }


@app.on_event("startup")
async def startup():
    global pipe, ipipe, tpipe
    pipe = load_pipeline()
    # Same UNet/VAE/encoders, zero extra memory — only the pipeline wrapper
    # differs. For non-inpaint checkpoints diffusers blends the unmasked
    # region back in latent space at every step, which is exactly what we
    # want: the canvas outside the mask is preserved by construction.
    from diffusers import AutoPipelineForInpainting, AutoPipelineForText2Image

    ipipe = AutoPipelineForInpainting.from_pipe(pipe)
    tpipe = AutoPipelineForText2Image.from_pipe(pipe)
    log.info("inpaint and text2img pipelines ready (shared weights)")


@app.get("/healthz")
async def healthz():
    return {"ok": pipe is not None, "model": MODEL_ID, "device": DEVICE}


@app.get("/img/{name}")
async def get_img(name: str):
    path = CACHE_DIR / name
    if not path.exists():
        raise HTTPException(404)
    media = "image/jpeg" if name.endswith(".jpg") else "image/png"
    return FileResponse(path, media_type=media)


def img_url(name: str) -> str:
    return f"http://{PUBLIC_HOST}:{BIND_PORT}/img/{name}"


@app.post("/generate")
async def generate(req: GenerateRequest):
    if pipe is None:
        raise HTTPException(503, "pipeline not ready")

    strength = req.strength if req.strength is not None else DEFAULT_STRENGTH
    steps = req.num_inference_steps if req.num_inference_steps is not None else DEFAULT_STEPS

    try:
        job = await asyncio.get_event_loop().run_in_executor(
            executor, run_job, req.prompt, req.image_url, strength, steps,
            req.camera, req.element, req.placement, req.style_pass,
        )
    except requests.RequestException as e:
        log.exception("input image fetch failed")
        raise HTTPException(400, f"fetch failed: {e}")

    t = job["timings"]
    log.info(
        "generated %s via %s (fetch %dms, infer %dms, morph %dms x%d frames)",
        job["final_name"],
        t["input_source"],
        t["fetch_ms"],
        t["infer_ms"],
        t["morph_ms"],
        len(job["frame_names"]) - 1,
    )

    return JSONResponse(
        {
            "images": [
                {
                    "url": img_url(job["final_name"]),
                    "width": job["width"],
                    "height": job["height"],
                }
            ],
            "frames": [img_url(n) for n in job["frame_names"]],
            "timings": t,
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
