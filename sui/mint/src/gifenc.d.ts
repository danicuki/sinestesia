// Minimal typings for gifenc (CommonJS, ships no .d.ts). Covers only the
// encoder + palette functions we use in compose.ts.
declare module 'gifenc' {
  type Palette = number[][];
  interface Encoder {
    writeFrame(
      index: Uint8Array,
      width: number,
      height: number,
      opts?: { palette?: Palette; delay?: number },
    ): void;
    finish(): void;
    bytes(): Uint8Array;
  }
  interface GifencModule {
    GIFEncoder(): Encoder;
    quantize(rgba: Uint8Array, maxColors: number, opts?: unknown): Palette;
    applyPalette(rgba: Uint8Array, palette: Palette, format?: string): Uint8Array;
  }
  const gifenc: GifencModule;
  export default gifenc;
}
