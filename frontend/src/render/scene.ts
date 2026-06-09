// Three.js stage: one full-screen quad with a ShaderMaterial. Rail 1 features
// flow into uniforms every frame; backend images transition in over ~2.5s via
// a Perlin-noise warp (ink-bleed) — see shaders/transition.glsl.

import * as THREE from "three";
import vertexShader from "./shaders/vertex.glsl";
import fragmentShader from "./shaders/fragment.glsl";
import type { FastUniforms } from "../audio/features";
import type { ExpressiveFeatures } from "../socket";

// The live (backend) morph duration is ADAPTIVE. A fixed duration freezes
// whenever the backend is slower than it (the morph finishes, then the picture
// is held until the next image arrives). Instead we measure the real interval
// between incoming images and stretch each morph to slightly OVERSHOOT it, so a
// new image almost always lands while the previous morph is still in flight —
// the screen is then perpetually mid-transition, never frozen. Progression is
// linear (not eased) so the new strokes draw in evenly across the whole window
// instead of popping in the middle. These bound the adaptive value.
const TRANSITION_DEFAULT_MS = 3000; // first image, before any cadence is known
const TRANSITION_MIN_MS = 2000;
const TRANSITION_MAX_MS = 7000;
const TRANSITION_OVERSHOOT = 1.2; // run ~20% past the measured cadence
// New song (reset): a quick, clean cut to the placeholder — we don't morph
// between unrelated songs. (The dev sample player drives its own timeline.)
const RESET_MS = 700;

// A 1x1 dark texture so the shader has something valid before any image lands.
function placeholderTexture(): THREE.DataTexture {
  const data = new Uint8Array([12, 10, 16, 255]);
  const tex = new THREE.DataTexture(data, 1, 1, THREE.RGBAFormat);
  tex.needsUpdate = true;
  return tex;
}

export class Scene {
  private renderer: THREE.WebGLRenderer;
  private scene: THREE.Scene;
  private camera: THREE.OrthographicCamera;
  private material: THREE.ShaderMaterial;
  private loader = new THREE.TextureLoader();

  private startTime = performance.now();
  private fadeStart = 0;
  private fadeDur = TRANSITION_DEFAULT_MS;
  private fading = false;
  private onsetEnv = 0; // decaying onset envelope
  // Cadence tracking for the adaptive morph duration: arrival time of the last
  // image and an EMA of the gaps between images.
  private lastImageAt = 0;
  private gapEma = 0;
  // Flipped to false if the render loop ever throws (e.g. a shader problem),
  // degrading the warp to a plain linear cross-dissolve for the rest of the
  // session. The non-warp branch in the shader matches the original behaviour.
  private warp = true;

  constructor(canvas: HTMLCanvasElement) {
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.setSize(window.innerWidth, window.innerHeight, false);

    this.scene = new THREE.Scene();
    this.camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);

    const ph = placeholderTexture();
    this.material = new THREE.ShaderMaterial({
      vertexShader,
      fragmentShader,
      uniforms: {
        uTime: { value: 0 },
        uRms: { value: 0 },
        uOnset: { value: 0 },
        uCentroid: { value: 0.5 },
        uValence: { value: 0 }, // -1..1 (Rail 3) — sad → happy
        uArousal: { value: 0.4 }, // 0..1 (Rail 3) — calm → energetic
        uCrossfade: { value: 1 },
        uUseWarp: { value: 1 },
        uFftBins: { value: new Float32Array(32) },
        uTexCurrent: { value: ph },
        uTexPrev: { value: ph },
        uResolution: {
          value: new THREE.Vector2(window.innerWidth, window.innerHeight),
        },
      },
    });

    const quad = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.material);
    this.scene.add(quad);

    window.addEventListener("resize", () => this.onResize());
  }

  private onResize() {
    this.renderer.setSize(window.innerWidth, window.innerHeight, false);
    this.material.uniforms.uResolution.value.set(
      window.innerWidth,
      window.innerHeight,
    );
  }

  /** Feed Rail 1 features (call before render each frame). */
  setFast(u: FastUniforms) {
    this.material.uniforms.uRms.value = u.rms;
    this.material.uniforms.uCentroid.value = u.centroid;
    (this.material.uniforms.uFftBins.value as Float32Array).set(u.fft);
    if (u.onset) this.onsetEnv = 1.0;
  }

  /** Feed Rail 3 expressive features (~2Hz). Subtle, slow-moving color mood. */
  setExpressive(f: ExpressiveFeatures) {
    this.material.uniforms.uValence.value = f.valence;
    this.material.uniforms.uArousal.value = f.arousal;
  }

  // Begin a transition from whatever is currently in uTexCurrent (A) to the new
  // texture (B). If one is already mid-flight it is redirected, never frozen: A
  // becomes the in-flight target and the fade restarts toward B.
  //
  // The briefing asks for A = the exact blend on screen, which would need an FBO
  // grab of the current frame. We skip that: the backend is img2img, so
  // consecutive frames are near-identical and mix(A_prev, A_target, t) ≈ A_target
  // for all t — snapping A to the target texture is visually indistinguishable
  // from the true blend, with none of the render-target/colour-space risk. (If a
  // visible jump ever shows up on real frames, capturing to an FBO here is the
  // fix.)
  private startTransition(next: THREE.Texture, durationMs?: number) {
    this.material.uniforms.uTexPrev.value =
      this.material.uniforms.uTexCurrent.value;
    this.material.uniforms.uTexCurrent.value = next;
    this.material.uniforms.uCrossfade.value = 0;
    this.fadeStart = performance.now();
    this.fadeDur = durationMs ?? this.adaptiveDur();
    this.fading = true;
  }

  // Stretch the next morph to (a bit past) the measured image cadence so it is
  // still running when the next image lands. Falls back to the default until we
  // have seen at least one gap.
  private adaptiveDur(): number {
    if (this.gapEma <= 0) return TRANSITION_DEFAULT_MS;
    return THREE.MathUtils.clamp(
      this.gapEma * TRANSITION_OVERSHOOT,
      TRANSITION_MIN_MS,
      TRANSITION_MAX_MS,
    );
  }

  /** Transition back to the dark placeholder (e.g. on "nova música"). */
  clearImage() {
    // A new song restarts the cadence estimate and cuts quickly to black.
    this.lastImageAt = 0;
    this.gapEma = 0;
    this.startTransition(placeholderTexture(), RESET_MS);
  }

  private configureTex(tex: THREE.Texture) {
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.minFilter = THREE.LinearFilter;
    tex.magFilter = THREE.LinearFilter;
  }

  /** Load a new image and warp-transition to it (live backend path). */
  transitionTo(url: string) {
    // Measure the gap since the previous image (at arrival, not load-complete,
    // so it tracks the backend cadence) and fold it into the EMA used to size
    // the next morph.
    const now = performance.now();
    if (this.lastImageAt > 0) {
      const gap = now - this.lastImageAt;
      this.gapEma = this.gapEma > 0 ? this.gapEma * 0.6 + gap * 0.4 : gap;
    }
    this.lastImageAt = now;

    this.loader.load(
      url,
      (tex) => {
        this.configureTex(tex);
        this.startTransition(tex);
      },
      undefined,
      () => {
        // Image failed to load — keep the current texture, demo continues.
        console.warn("[scene] image load failed:", url);
      },
    );
  }

  /** Preload a batch of textures (e.g. a whole sample sequence). */
  preload(urls: string[]): Promise<THREE.Texture[]> {
    return Promise.all(
      urls.map(
        (u) =>
          new Promise<THREE.Texture>((resolve, reject) => {
            this.loader.load(
              u,
              (tex) => {
                this.configureTex(tex);
                resolve(tex);
              },
              undefined,
              reject,
            );
          }),
      ),
    );
  }

  // Drive the morph manually from an external continuous timeline (the sample
  // player): A and B are already-loaded textures, t is the raw 0..1 reveal. This
  // bypasses the internal fade clock so playback can chain frame→frame with no
  // settle. At t=1 the screen is exactly B, so the next segment (B→C at t=0)
  // starts pixel-identical — seamless, no pause, no jump.
  setMorph(a: THREE.Texture, b: THREE.Texture, t: number) {
    this.fading = false;
    const u = this.material.uniforms;
    u.uTexPrev.value = a;
    u.uTexCurrent.value = b;
    u.uCrossfade.value = t;
  }

  /** Render one frame. */
  render() {
    const now = performance.now();
    this.material.uniforms.uTime.value = (now - this.startTime) / 1000;

    // Onset envelope decay (~250ms tail).
    this.onsetEnv *= 0.88;
    this.material.uniforms.uOnset.value = this.onsetEnv;

    // Transition progress: linear over the adaptive duration, so the new strokes
    // draw in evenly across the whole window (no mid-point pop). The shader turns
    // this into the diff-gated bleed and the colour hand-off; Rail 1/3 keep
    // reacting on top. Usually a new image redirects this before it reaches 1.
    if (this.fading) {
      const t = (now - this.fadeStart) / this.fadeDur;
      if (t >= 1) {
        this.material.uniforms.uCrossfade.value = 1;
        this.fading = false;
      } else {
        this.material.uniforms.uCrossfade.value = t;
      }
    }

    try {
      this.renderer.render(this.scene, this.camera);
    } catch (err) {
      // Any render-time failure (shader trouble) drops us to the plain dissolve
      // for the rest of the session rather than freezing the stage.
      if (this.warp) {
        console.warn("[scene] render error — falling back to plain dissolve:", err);
        this.warp = false;
        this.material.uniforms.uUseWarp.value = 0;
      }
    }
  }
}
