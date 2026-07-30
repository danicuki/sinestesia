import { createHash } from 'node:crypto';

/**
 * The live-performance record that proves *how* a painting was made. Hashing
 * this is what turns the NFT from "an image" into "proof of the exact live
 * moment that produced it".
 */
/** Which model produced a given artefact. */
export interface ModelRef {
  provider?: string | null;
  model?: string | null;
  route?: string | null;
  steps?: number | null;
}

/** Every model in the chain that produced the painting. */
export interface ModelsUsed {
  /** Speech-to-text that produced the transcript. */
  stt?: ModelRef;
  /** Every Director model that ran (the chain can fall back mid-song). */
  director?: ModelRef[];
  /** The image model, including which route/steps actually rendered. */
  image?: ModelRef;
  /** "t2i" or "img2img" — how each frame was built. */
  renderMode?: string | null;
}

/** Proof that one Director turn ran on verifiable compute. */
export interface ChatProof {
  /** The provider-issued chat id the TEE signature is retrievable by. */
  chatId?: string | null;
  provider?: string | null;
  model?: string | null;
  network?: string | null;
  /** true = TEE signature verified; false = checked and failed; null = unresolved. */
  verified?: boolean | null;
}

export interface Performance {
  song: string;
  artist: string;
  venue: string;
  /** Full lyric transcript captured by STT during the song. */
  transcript: string;
  /** Every prompt the Director model emitted, in order. */
  directorPrompts: string[];
  /** ISO timestamps aligned with each prompt (must match prompt count). */
  timestamps: string[];
  /** Model that produced each prompt, aligned with `directorPrompts`. */
  directorModels?: (ModelRef | null)[];
  /**
   * The sung line each prompt was answering, aligned with `directorPrompts`.
   * Without it the record shows only the Director's half of the exchange.
   */
  directorLyrics?: (string | null)[];
  /**
   * Verifiable-inference receipt per prompt, aligned with `directorPrompts`.
   * `null` where that turn didn't run on 0G — the Director chain can fall back
   * mid-song, and the record should say so rather than imply uniform proof.
   */
  directorProofs?: (ChatProof | null)[];
  /** The full model chain — the "how it was made" half of the certificate. */
  models?: ModelsUsed;
  /** Unix ms when the song ended. */
  endedAtMs: number;
}

/**
 * The exact bytes the provenance hash is taken over — the hash PREIMAGE.
 *
 * Exported (not inlined into `provenanceHash`) because a hash nobody can open is
 * not a certificate of authenticity: publishing this alongside the NFT is what
 * lets anyone recompute the hash and read which prompts and which models
 * produced the painting.
 *
 * Field order and separators are fixed so the same performance always hashes
 * identically. Anything added here changes the hash of future mints by design.
 */
export function canonicalProvenance(p: Performance): string {
  if (p.directorPrompts.length !== p.timestamps.length) {
    throw new Error(
      `prompts (${p.directorPrompts.length}) and timestamps (${p.timestamps.length}) must be 1:1`,
    );
  }
  return JSON.stringify({
    song: p.song,
    artist: p.artist,
    venue: p.venue,
    transcript: p.transcript,
    steps: p.directorPrompts.map((prompt, i) => ({
      t: p.timestamps[i],
      // The exchange, not just the answer: what was sung, what the Director
      // replied, which model wrote it, and the receipt proving where it ran.
      lyric: p.directorLyrics?.[i] ?? null,
      prompt,
      model: p.directorModels?.[i] ?? null,
      proof: p.directorProofs?.[i] ?? null,
    })),
    models: p.models ?? null,
    endedAtMs: p.endedAtMs,
  });
}

/** Canonical SHA-256 of the performance, taken over `canonicalProvenance`. */
export function provenanceHash(p: Performance): string {
  return createHash('sha256').update(canonicalProvenance(p), 'utf8').digest('hex');
}
