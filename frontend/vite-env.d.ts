/// <reference types="vite/client" />

declare module "*.glsl" {
  const value: string;
  export default value;
}

// essentia.js has no bundled types; we use it loosely in the worker.
declare module "essentia.js";
