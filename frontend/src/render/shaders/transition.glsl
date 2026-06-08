// Perlin-noise warp transition between the previous and current AI image.
// Included into fragment.glsl, so it relies on these uniforms being declared
// there already: uTime, uTexPrev, uTexCurrent.
//
// The look we're after: ink bleeding from the old sketch into the new one.
// Instead of a flat opacity dissolve, both frames are pushed around by a slow
// Perlin field whose amplitude peaks at the middle of the transition (t*(1-t))
// and falls back to zero at both ends — so we land cleanly on the new image.

// --- Classic Perlin noise 2D (Stefan Gustavson / Ashima, classicnoise2D.glsl) ---
vec4 mod289(vec4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec4 permute(vec4 x) { return mod289(((x * 34.0) + 1.0) * x); }
vec4 taylorInvSqrt(vec4 r) { return 1.79284291400159 - 0.85373472095314 * r; }
vec2 fade(vec2 t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }

float cnoise(vec2 P) {
  vec4 Pi = floor(P.xyxy) + vec4(0.0, 0.0, 1.0, 1.0);
  vec4 Pf = fract(P.xyxy) - vec4(0.0, 0.0, 1.0, 1.0);
  Pi = mod289(Pi);
  vec4 ix = Pi.xzxz;
  vec4 iy = Pi.yyww;
  vec4 fx = Pf.xzxz;
  vec4 fy = Pf.yyww;
  vec4 i = permute(permute(ix) + iy);
  vec4 gx = fract(i * (1.0 / 41.0)) * 2.0 - 1.0;
  vec4 gy = abs(gx) - 0.5;
  vec4 tx = floor(gx + 0.5);
  gx = gx - tx;
  vec2 g00 = vec2(gx.x, gy.x);
  vec2 g10 = vec2(gx.y, gy.y);
  vec2 g01 = vec2(gx.z, gy.z);
  vec2 g11 = vec2(gx.w, gy.w);
  vec4 norm = taylorInvSqrt(
    vec4(dot(g00, g00), dot(g01, g01), dot(g10, g10), dot(g11, g11)));
  g00 *= norm.x;
  g01 *= norm.y;
  g10 *= norm.z;
  g11 *= norm.w;
  float n00 = dot(g00, vec2(fx.x, fy.x));
  float n10 = dot(g10, vec2(fx.y, fy.y));
  float n01 = dot(g01, vec2(fx.z, fy.z));
  float n11 = dot(g11, vec2(fx.w, fy.w));
  vec2 fade_xy = fade(Pf.xy);
  vec2 n_x = mix(vec2(n00, n01), vec2(n10, n11), fade_xy.x);
  float n_xy = mix(n_x.x, n_x.y, fade_xy.y);
  return 2.3 * n_xy;
}

// --- Tunables ---
// Diff thresholds: a pixel whose colour barely changes between the two frames
// is held perfectly still; above CHANGE_HI it is treated as genuinely new
// content and animates. (length() of an RGB difference, range ~0..1.7.)
const float CHANGE_LO = 0.06;
const float CHANGE_HI = 0.22;
// Bleed displacement (UV units) applied ONLY to changing pixels at the midpoint
// of the transition. Deliberately tiny — a gentle waver as a stroke draws in,
// not a wave across the whole image.
const float BLEED_AMP = 0.02;
// Low-frequency flow giving the bleed an organic direction.
const float FLOW_SCALE = 2.5;
const float FLOW_DRIFT = 0.04;

float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// t is the transition progress (0 = fully prev, 1 = fully current).
//
// The backend images are accumulative (B = A + a new element), so the only
// thing that should appear to move is what actually differs between the two
// frames. We mask by the per-pixel A↔B difference: shared content is left
// completely still, and just the new strokes ease in with a subtle bleed. No
// global warp, no slideshow crossfade of the whole picture.
vec3 transitionSample(vec2 uv, float t) {
  vec3 a0 = texture2D(uTexPrev, uv).rgb;
  vec3 b0 = texture2D(uTexCurrent, uv).rgb;

  // How much this pixel changes from A to B. ~0 over shared content.
  float diff = length(b0 - a0);
  float changing = smoothstep(CHANGE_LO, CHANGE_HI, diff);

  // Subtle bleed: tiny, only where something changes, peaking mid-transition
  // and vanishing at t=0/1. Everything else stays rock-still.
  float bell = t * (1.0 - t) * 4.0;
  vec2 flow = vec2(
    cnoise(uv * FLOW_SCALE + vec2(uTime * FLOW_DRIFT, 0.0)),
    cnoise(uv * FLOW_SCALE + vec2(7.3, uTime * FLOW_DRIFT))
  );
  vec2 disp = flow * (bell * changing * BLEED_AMP);

  vec3 a = texture2D(uTexPrev, uv + disp).rgb;
  vec3 b = texture2D(uTexCurrent, uv - disp).rgb;

  // Cross-dissolve over the segment. Where a≈b (shared content) this is a no-op
  // regardless of t, so it looks static; only the differing strokes resolve.
  return mix(a, b, t);
}
