// Three.js stage: one full-screen quad with a ShaderMaterial. Rail 1 features
// flow into uniforms every frame; backend images transition in over ~2.5s via
// a Perlin-noise warp (ink-bleed) — see shaders/transition.glsl.

import * as THREE from "three";
import vertexShader from "./shaders/vertex.glsl";
import fragmentShader from "./shaders/fragment.glsl";
import type { FastUniforms } from "../audio/features";
import type { ExpressiveFeatures } from "../socket";

// Duration of one live (backend) morph: the diff-masked shader eases the new
// strokes in over this window. Kept just under the backend's 3-5s image cadence
// so a morph normally completes before the next image lands — clean finishes
// instead of mid-flight restarts. Between images the picture is held, but live
// audio (Rail 1) keeps animating it, so it never looks frozen. (The dev sample
// player drives its own continuous timeline and does not use this constant.)
const TRANSITION_MS = 2800;

// easeInOutCubic — slow start, slow end, so the bleed feels deliberate.
function easeInOutCubic(t: number): number {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

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
  private fadeDur = TRANSITION_MS;
  private fading = false;
  private onsetEnv = 0; // decaying onset envelope
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
  // texture (B). If a transition is already mid-flight it is cancelled: A
  // becomes the in-flight target so a fresh warp starts from it. (True A would
  // be the live blend on screen, but capturing that needs an FBO grab — out of
  // scope for the single-pass path; the jump is brief and rarely visible since
  // images arrive every 3-5s vs a 2.5s transition.)
  private startTransition(next: THREE.Texture) {
    this.material.uniforms.uTexPrev.value =
      this.material.uniforms.uTexCurrent.value;
    this.material.uniforms.uTexCurrent.value = next;
    this.material.uniforms.uCrossfade.value = 0;
    this.fadeStart = performance.now();
    this.fadeDur = TRANSITION_MS;
    this.fading = true;
  }

  /** Transition back to the dark placeholder (e.g. on "nova música"). */
  clearImage() {
    this.startTransition(placeholderTexture());
  }

  private configureTex(tex: THREE.Texture) {
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.minFilter = THREE.LinearFilter;
    tex.magFilter = THREE.LinearFilter;
  }

  /** Load a new image and warp-transition to it (live backend path). */
  transitionTo(url: string) {
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

    // Transition progress: easeInOutCubic over TRANSITION_MS. The shader turns
    // this into both the Perlin warp amplitude (peaks at t=0.5) and the colour
    // hand-off, so Rail 1/3 keep reacting on top of the bleed.
    if (this.fading) {
      const t = (now - this.fadeStart) / this.fadeDur;
      if (t >= 1) {
        this.material.uniforms.uCrossfade.value = 1;
        this.fading = false;
      } else {
        this.material.uniforms.uCrossfade.value = easeInOutCubic(t);
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
