import { createHash } from 'node:crypto';

/**
 * The live-performance record that proves *how* a painting was made. Hashing
 * this is what turns the NFT from "an image" into "proof of the exact live
 * moment that produced it".
 */
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
  /** Unix ms when the song ended. */
  endedAtMs: number;
}

/**
 * Canonical SHA-256 of the performance. Field order and separators are fixed so
 * the same performance always hashes identically and can be re-verified from
 * the stored transcript + prompts.
 */
export function provenanceHash(p: Performance): string {
  if (p.directorPrompts.length !== p.timestamps.length) {
    throw new Error(
      `prompts (${p.directorPrompts.length}) and timestamps (${p.timestamps.length}) must be 1:1`,
    );
  }
  const canonical = JSON.stringify({
    song: p.song,
    artist: p.artist,
    venue: p.venue,
    transcript: p.transcript,
    steps: p.directorPrompts.map((prompt, i) => ({ t: p.timestamps[i], prompt })),
    endedAtMs: p.endedAtMs,
  });
  return createHash('sha256').update(canonical, 'utf8').digest('hex');
}
