// Three.js stage: one full-screen quad with a ShaderMaterial. Rail 1 features
// flow into uniforms every frame; backend images crossfade in over ~600ms.

import * as THREE from "three";
import vertexShader from "./shaders/vertex.glsl";
import fragmentShader from "./shaders/fragment.glsl";
import type { FastUniforms } from "../audio/features";

const CROSSFADE_MS = 600;

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
  private fading = false;
  private onsetEnv = 0; // decaying onset envelope

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
        uCrossfade: { value: 1 },
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
    (this.material.uniforms.uFftBins.value as Float32Array).set(u.fft);
    if (u.onset) this.onsetEnv = 1.0;
  }

  /** Load a new image and crossfade to it. */
  crossfadeTo(url: string) {
    this.loader.load(
      url,
      (tex) => {
        tex.colorSpace = THREE.SRGBColorSpace;
        tex.minFilter = THREE.LinearFilter;
        tex.magFilter = THREE.LinearFilter;
        this.material.uniforms.uTexPrev.value =
          this.material.uniforms.uTexCurrent.value;
        this.material.uniforms.uTexCurrent.value = tex;
        this.material.uniforms.uCrossfade.value = 0;
        this.fadeStart = performance.now();
        this.fading = true;
      },
      undefined,
      () => {
        // Image failed to load — keep the current texture, demo continues.
        console.warn("[scene] image load failed:", url);
      },
    );
  }

  /** Render one frame. */
  render() {
    const now = performance.now();
    this.material.uniforms.uTime.value = (now - this.startTime) / 1000;

    // Onset envelope decay (~250ms tail).
    this.onsetEnv *= 0.88;
    this.material.uniforms.uOnset.value = this.onsetEnv;

    // Crossfade easing.
    if (this.fading) {
      const t = (now - this.fadeStart) / CROSSFADE_MS;
      if (t >= 1) {
        this.material.uniforms.uCrossfade.value = 1;
        this.fading = false;
      } else {
        // smoothstep ease in/out
        this.material.uniforms.uCrossfade.value = t * t * (3 - 2 * t);
      }
    }

    this.renderer.render(this.scene, this.camera);
  }
}
