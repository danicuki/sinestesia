// Pass-through: full-screen quad, hand UVs to the fragment shader.
varying vec2 vUv;

void main() {
  vUv = uv;
  gl_Position = vec4(position, 1.0);
}
