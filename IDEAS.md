# Sinestesia — Improvement Ideas

Backlog of post-hackathon improvement ideas, from a full project review (2026-06-10).
Roughly ordered by impact-per-effort within each section. Check items off as they land.

## Wow factor — image, continuity, "video"

- [x] **Latent interpolation in the sidecar** *(implemented — see `local-sdxl/server.py`)*
  Instead of crossfading PNGs in the frontend, slerp between the previous frame's
  latents and the new frame's latents inside the SDXL sidecar and decode N
  intermediate frames with TAESD (~30-50ms per decode at 768×432). The result is a
  *generative morph* (shapes transforming) rather than a pixel dissolve, for ~300ms
  of extra GPU per cycle. Frames ship to the frontend via the `frames` field on the
  `image` message (PROTOCOL.md).

- [x] **Latent cache in the sidecar** *(implemented — see `local-sdxl/server.py`)*
  Keep the output latents of each generation in memory keyed by image name. The next
  img2img call feeds them straight back in, eliminating the HTTP self-fetch (~80ms),
  the VAE re-encode (~50-100ms on MPS), and — most importantly — the generational
  decode/encode loss of chaining TAESD round-trips, which slowly degrades the canvas
  over a song.

- [x] **Operator camera (zoom/pan) — "cameraman joystick"** *(backend + sidecar
  implemented 2026-06-10; frontend UI pending)*
  The first image anchors the whole img2img chain: a dominant opening element (the
  giant Aquarela sun) keeps ~80% of the canvas forever, because low-frequency
  structure survives every denoise. Fix: an operator-driven virtual camera. The
  frontend sends `{type: "camera", zoom, pan_x, pan_y}` (-1..1); the sidecar warps
  the previous frame's latents accordingly before each img2img, so the scene
  recedes/slides and the revealed edges are repainted with new content. v1 UI =
  a zoom-out toggle; the same protocol supports the full 6-direction joystick.
  An automatic version (feedback controller on the per-frame latent diff: bump
  strength / nudge zoom when visual change stagnates for N frames) remains a
  future option — see "adaptive change controller" below.

- [ ] **Adaptive change controller**
  The sidecar holds input and output latents per frame; their distance measures
  visual change for free. Keep an EMA; if change stays below a floor for N frames
  (canvas saturated), raise strength a notch and/or apply a small zoom-out for that
  frame; if above a ceiling, lower strength. Keeps the "drawing speed" in a healthy
  band for any song without operator input. Complements the manual camera.

- [ ] **Fixed seed per song**
  Each generation currently samples fresh noise, causing texture "simmering" between
  frames (backgrounds churn for no reason). A `torch.Generator` seeded per session
  (re-seeded on "nova música") stabilizes shared content so only the new element
  changes. One line.

- [ ] **Stroke-by-stroke reveal synced to onsets** *(frontend, zero AI)*
  `transition.glsl` already has the diff mask and the Perlin field. Instead of
  dissolving the new element uniformly, use the noise value as a reveal threshold
  (`step(noise, t)` on changing pixels) so new elements get *painted in* like brush
  strokes. Advance `t` in steps on onsets (`uOnset` already exists) so strokes land
  on the rhythm of the voice.

- [ ] **2.5D depth parallax**
  Run Depth-Anything-V2-Small (~25-30ms) once per generated image (every ~3s —
  negligible budget) and send the depth map alongside. The shader does parallax
  displacement driven by FFT/RMS: the static sketch becomes a diorama that sways
  with the music.

- [ ] **StreamDiffusion / sd-turbo "live video" mode** *(bigger bet)*
  sd-turbo (SD 2.1, much smaller than SDXL) at 512×512, 1 step, TAESD can run
  continuous img2img at a few fps on M4 Max — a stream where vocal RMS modulates
  `strength` (sing louder = the image boils harder). True audio-reactive generative
  video. Risk: GPU contention with Gemma. Best as a separate operator-triggered
  "climax mode" for choruses.

- [ ] **ControlNet / IP-Adapter for harder continuity**
  A canny/scribble ControlNet conditioned on the previous frame would preserve
  composition at higher strength (more visual refresh without drift). Adds ~2x
  latency; optional mode.

- [ ] **LoRA for the sketch style**
  Train on 50-100 sketch images; load via `pipe.load_lora_weights(...)`. Frees the
  CLIP token budget currently spent on the style suffix and makes the look
  consistent without prompt engineering.

## Cost / sovereignty

- [ ] **Local text2image bootstrap** — the only paid frame left is the fal Schnell
  first frame. `AutoPipelineForText2Image.from_pipe(pipe)` reuses the already-loaded
  sdxl-turbo weights with zero extra memory. Add a t2i branch to `/generate` when
  `image_url` is null → kills the FAL key and the internet dependency for visuals.
  Show runs 100% offline (only STT remains cloud).

- [ ] **PNG → JPEG/WebP serving** — PNG at 768×432 costs tens of ms to encode and
  ~600KB+ per frame; JPEG q90 encodes and loads faster. Indistinguishable for the
  sketch look. (Morph intermediate frames already ship as JPEG.)

- [ ] **Smaller Director model** — with ≤15-word outputs, Gemma 4B / Qwen3 4B likely
  matches the 12B at ~⅓ the latency and frees GPU for SDXL (the exact contention
  that blew up latency before). Worth a 30-minute A/B.

- [ ] **Local STT, take two** — ElevenLabs is the only recurring cost. If revisiting
  local: parakeet-mlx (NVIDIA Parakeet TDT on Apple Silicon) is much faster than
  whisper-small and barely touches the GPU. Sung lyrics remain the hard part for any
  STT; rehearsal-test only.

## Realtime audio → visual without waiting for AI

Strategic insight: the 2-3s of Rail 2 is irreducible — the game is filling the wait
with instant response so the audience never feels the gap. Rail 1 today is subtle
(wobble + hue + grain). All of the below are model-free:

- [ ] **The melody draws** *(favorite — the project's concept in pure form)*
  Cheap pitch tracking (autocorrelation/YIN on the time-domain buffer we already
  have) → trace the melodic contour as a hand-drawn line that travels the screen in
  the same sepia sketch style, then dissolves into the canvas. The voice literally
  draws in <50ms while the AI prepares the next scene.

- [ ] **Instant calligraphy lyrics**
  Interim transcripts arrive in ~300ms and today only feed the debug overlay. Render
  the words as handwriting that writes itself (stroke-dash animation), floats, and
  gets "absorbed" when the new image lands. The audience sees the word they just
  heard become a drawing.

- [ ] **Feedback buffer (ping-pong FBO) for persistent ink**
  Onsets splatter ink blots at positions derived from pitch/centroid; the feedback
  buffer diffuses and fades them over seconds, multiplied over the sketch. Classic
  VJ trick, pure GPU, fits the watercolor aesthetic perfectly.

- [ ] **Beat tracking → everything pulses in tempo**
  Simple tempo estimation over onsets (or Essentia's RhythmExtractor, already
  loaded) so the zoom-punch and morph progression quantize to the beat instead of
  reacting loosely.

- [ ] **Close the README caveat: Rail 3 → Director**
  Valence/arousal reach the backend and die in the shader. Append a mood hint to the
  Director's user message ("mood: melancholic, energy: low") — zero added latency,
  the scene respects the emotion, not just the words.
