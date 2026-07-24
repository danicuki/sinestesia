import { provenanceHash, type Performance } from './provenance.js';
import { deriveTraits } from './traits.js';
import type { Storage, StoredImage } from './storage/types.js';
import type { Minter, ReleaseReceipt } from './chains/types.js';

export interface CreateReleaseInput {
  image: Uint8Array | Buffer;
  performance: Performance;
  storage: Storage;
  /** One or more chains — release the same painting on all of them in parallel. */
  minters: Minter[];
}

export interface CreateReleaseResult {
  stored: StoredImage;
  provenanceHash: string;
  traits: Record<string, string | number>;
  releases: ReleaseReceipt[];
}

/**
 * The chain-agnostic pipeline for a finished song: store the image once, hash
 * the performance once, derive traits once, then create the release (master 1/1
 * + open print window) on every configured chain. Adding a blockchain is just
 * another `Minter` — nothing else changes.
 */
export async function createRelease(input: CreateReleaseInput): Promise<CreateReleaseResult> {
  const { image, performance, storage, minters } = input;

  const stored = await storage.store(image);
  const hash = provenanceHash(performance);
  const traits = deriveTraits(performance);

  const req = {
    song: performance.song,
    artist: performance.artist,
    venue: performance.venue,
    imageUri: stored.uri,
    imageStorageId: stored.id,
    storageBackend: stored.backend,
    provenanceHash: hash,
    createdAtMs: performance.endedAtMs,
    traits,
  };

  const releases = await Promise.all(minters.map((m) => m.createRelease(req)));
  return { stored, provenanceHash: hash, traits, releases };
}
