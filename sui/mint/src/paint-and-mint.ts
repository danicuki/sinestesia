import { canonicalProvenance, provenanceHash, type Performance } from './provenance.js';
import { deriveTraits } from './traits.js';
import type { Storage, StoredImage } from './storage/types.js';
import type { Minter, ReleaseReceipt } from './chains/types.js';

export interface CreateReleaseInput {
  image: Uint8Array | Buffer;
  performance: Performance;
  storage: Storage;
  /** One or more chains — release the same painting on all of them in parallel. */
  minters: Minter[];
  /**
   * Optional: derive the on-chain `image_url` from the stored blob (e.g. a
   * content-type-serving proxy URL). Defaults to the raw storage URL. The
   * canonical `walrus_blob_id` is always stored regardless, so the blob stays
   * independently retrievable.
   */
  imageUrl?: (stored: StoredImage) => string;
}

export interface CreateReleaseResult {
  stored: StoredImage;
  provenanceHash: string;
  /** Where the hash PREIMAGE lives, so the certificate can actually be opened. */
  provenance: StoredImage;
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

  // Store the painting AND the provenance preimage. Minting only the hash left
  // the certificate sealed: nobody could see the prompts or the models behind
  // the artwork, or recompute the hash to check it. Both go to the same backend,
  // so the proof is as durable and as public as the image itself.
  const canonical = canonicalProvenance(performance);
  const [stored, provenance] = await Promise.all([
    storage.store(image),
    storage.store(Buffer.from(canonical, 'utf8')),
  ]);
  const hash = provenanceHash(performance);

  // Carried in `traits` (already an arbitrary on-chain JSON field) so the
  // preimage is reachable from the NFT without changing the Move contract.
  const traits = {
    ...deriveTraits(performance),
    provenance_blob: provenance.id,
    provenance_uri: provenance.uri,
  };

  const req = {
    song: performance.song,
    artist: performance.artist,
    venue: performance.venue,
    imageUri: input.imageUrl ? input.imageUrl(stored) : stored.uri,
    imageStorageId: stored.id,
    storageBackend: stored.backend,
    provenanceHash: hash,
    createdAtMs: performance.endedAtMs,
    traits,
  };

  const releases = await Promise.all(minters.map((m) => m.createRelease(req)));
  return { stored, provenance, provenanceHash: hash, traits, releases };
}
