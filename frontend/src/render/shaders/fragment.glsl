// Sinestesia fragment shader.
//
// Crossfades between two AI-generated textures and modulates them live from the
// voice (Rail 1): FFT bands warp the UVs, RMS lifts saturation, onsets flash.
// Designed to keep the image legible while feeling "alive".

precision highp float;

varying vec2 vUv;

uniform float uTime;       // seconds
uniform float uRms;        // 0..1 overall energy
uniform float uOnset;      // 0..1, decays after each onset
uniform float uCentroid;   // 0..1 spectral centroid (0 = bass/warm, 1 = treble/cool)
uniform float uValence;    // -1..1 (Rail 3) sad -> happy
uniform float uArousal;    // 0..1 (Rail 3) calm -> energetic
uniform float uCrossfade;  // 0 = prev, 1 = current
uniform float uFftBins[32];
uniform sampler2D uTexCurrent;
uniform sampler2D uTexPrev;
uniform vec2 uResolution;

// Pick an FFT band (0..31) with linear interpolation.
float band(float idx) {
  int i = int(floor(idx));
  // GLSL ES 1.0 can't dynamically index a uniform array in all drivers via a
  // variable cleanly, so unrolled-ish access through a clamp-and-compare ladder
  // is avoided by relying on constant-index in a loop below instead.
  float v = 0.0;
  for (int k = 0; k < 32; k++) {
    if (k == i) v = uFftBins[k];
  }
  return v;
}

vec3 sampleScene(vec2 uv) {
  vec3 prev = texture2D(uTexPrev, uv).rgb;
  vec3 cur = texture2D(uTexCurrent, uv).rgb;
  return mix(prev, cur, clamp(uCrossfade, 0.0, 1.0));
}

// Cheap luminance-preserving saturation.
vec3 saturate3(vec3 c, float amt) {
  float l = dot(c, vec3(0.299, 0.587, 0.114));
  return mix(vec3(l), c, amt);
}

// Hue rotation around the luma axis (YIQ), in radians. Keeps brightness.
vec3 hueRotate(vec3 c, float angle) {
  const mat3 toYIQ = mat3(
    0.299,  0.587,  0.114,
    0.596, -0.274, -0.322,
    0.211, -0.523,  0.312
  );
  const mat3 toRGB = mat3(
    1.0,  0.956,  0.621,
    1.0, -0.272, -0.647,
    1.0, -1.106,  1.703
  );
  vec3 yiq = toYIQ * c;
  float cs = cos(angle), sn = sin(angle);
  yiq = vec3(yiq.x, yiq.y * cs - yiq.z * sn, yiq.y * sn + yiq.z * cs);
  return toRGB * yiq;
}

// Hash-based grain.
float grain(vec2 uv, float t) {
  return fract(sin(dot(uv * t, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
  vec2 uv = vUv;

  // --- FFT-driven UV displacement ---
  // Low bands push vertically (breathing), high bands ripple horizontally.
  float low = (band(1.0) + band(2.0) + band(3.0)) / 3.0;
  float mid = (band(8.0) + band(10.0) + band(12.0)) / 3.0;
  float high = (band(20.0) + band(24.0) + band(28.0)) / 3.0;

  float wobble = 0.012 * low * sin(uv.y * 9.0 + uTime * 1.5);
  float ripple = 0.008 * high * sin(uv.x * 40.0 + uTime * 6.0);
  uv.x += wobble + ripple;
  uv.y += 0.010 * mid * cos(uv.x * 7.0 + uTime * 1.2);

  // Onset gives a quick radial zoom-punch from center.
  vec2 c = uv - 0.5;
  uv = 0.5 + c * (1.0 - 0.04 * uOnset);

  vec3 col = sampleScene(uv);

  // --- Spectral centroid -> hue tint (Rail 1) ---
  // Bass-heavy voice tilts warm, bright/airy voice tilts cool. Centered so a
  // mid centroid leaves the image untouched. Subtle: ~±0.35 rad swing.
  col = hueRotate(col, (0.5 - uCentroid) * 0.7);

  // --- RMS -> brightness/opacity + saturation (Rail 1) ---
  // Louder = brighter and more saturated; quiet dips the image toward dark so
  // the stage breathes with the voice.
  col = saturate3(col, 1.0 + 0.6 * uRms);
  col *= 0.78 + 0.45 * uRms; // loudness drives overall brightness
  col += 0.15 * uRms * col;  // gentle bloom on top

  // --- Rail 3 expressive mood (slow, ~2Hz) ---
  // Positive valence warms + saturates a touch; low arousal softens contrast so
  // calm passages feel hazy, high arousal crisps them up.
  col = saturate3(col, 1.0 + 0.25 * uValence);
  col = hueRotate(col, -0.12 * uValence);
  float contrast = 0.85 + 0.4 * uArousal;
  col = (col - 0.5) * contrast + 0.5;

  // Onset flash: brighten + slight contrast pop.
  col += 0.25 * uOnset;
  col = (col - 0.5) * (1.0 + 0.2 * uOnset) + 0.5;

  // Subtle film grain, stronger when quiet so silence isn't dead-flat.
  float g = grain(vUv, uTime * 60.0) - 0.5;
  col += g * (0.04 + 0.03 * (1.0 - uRms));

  // Vignette for stage focus.
  float vig = smoothstep(1.1, 0.3, length(vUv - 0.5));
  col *= mix(0.75, 1.0, vig);

  gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
