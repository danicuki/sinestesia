import { provenanceHash, type Performance } from './provenance.js';
import { deriveTraits } from './traits.js';
import type { Storage, StoredImage } from './storage/types.js';
import type { Minter, MintReceipt } from './chains/types.js';

export interface PaintAndMintInput {
  image: Uint8Array | Buffer;
  performance: Performance;
  storage: Storage;
  /** One or more chains — mint the same painting to all of them in parallel. */
  minters: Minter[];
  recipient?: string;
  edition?: number;
}

export interface PaintAndMintResult {
  stored: StoredImage;
  provenanceHash: string;
  traits: Record<string, string | number>;
  receipts: MintReceipt[];
}

/**
 * The chain-agnostic pipeline: store the image once, hash the performance once,
 * derive traits once, then mint to every configured chain. Adding a blockchain
 * is just passing another `Minter` — nothing else changes.
 */
export async function paintAndMint(input: PaintAndMintInput): Promise<PaintAndMintResult> {
  const { image, performance, storage, minters, recipient, edition } = input;

  const stored = await storage.store(image);
  const hash = provenanceHash(performance);
  const traits = deriveTraits(performance);

  const req = {
    name: `Sinestesia — ${performance.song}`,
    song: performance.song,
    artist: performance.artist,
    venue: performance.venue,
    imageUri: stored.uri,
    imageStorageId: stored.id,
    storageBackend: stored.backend,
    provenanceHash: hash,
    createdAtMs: performance.endedAtMs,
    traits,
    recipient,
    edition,
  };

  const receipts = await Promise.all(minters.map((m) => m.mint(req)));
  return { stored, provenanceHash: hash, traits, receipts };
}
