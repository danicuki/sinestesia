import { defineConfig } from "vite";
import glsl from "vite-plugin-glsl";

export default defineConfig({
  plugins: [glsl()],
  server: {
    port: 5173,
  },
  // The expressive Web Worker is a module worker that code-splits essentia.js;
  // ES output is required (the default iife can't do code-splitting).
  worker: {
    format: "es",
  },
  // essentia.js ships a large prebuilt WASM glue file; don't let Vite try to
  // pre-bundle it into the dep optimizer (it breaks the wasm loader).
  optimizeDeps: {
    exclude: ["essentia.js"],
  },
});
