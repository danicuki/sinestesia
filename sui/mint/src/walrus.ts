import { readFile } from 'node:fs/promises';
import { walrusPublisher, walrusAggregator, walrusEpochs } from './config.js';

export interface StoredBlob {
  blobId: string;
  /** Aggregator URL where the bytes can be read back. */
  url: string;
  /** true if this exact blob already existed on Walrus (cost 0 to re-store). */
  alreadyCertified: boolean;
  /** The Sui object id of the blob registration, when newly created. */
  suiObjectId?: string;
}

/**
 * Store raw bytes on Walrus via a public publisher.
 *
 * Walrus returns one of two shapes: `newlyCreated` (we paid to store it) or
 * `alreadyCertified` (identical bytes were already stored). We normalise both
 * to a single `blobId` + read URL.
 */
export async function storeBytes(
  bytes: Uint8Array | Buffer,
  epochs: number = walrusEpochs,
): Promise<StoredBlob> {
  const res = await fetch(`${walrusPublisher}/v1/blobs?epochs=${epochs}`, {
    method: 'PUT',
    body: new Blob([bytes as BlobPart]),
  });
  if (!res.ok) {
    throw new Error(`Walrus store failed: ${res.status} ${await res.text()}`);
  }
  const json = (await res.json()) as WalrusStoreResponse;

  if ('newlyCreated' in json) {
    const blobId = json.newlyCreated.blobObject.blobId;
    return {
      blobId,
      url: blobUrl(blobId),
      alreadyCertified: false,
      suiObjectId: json.newlyCreated.blobObject.id,
    };
  }
  if ('alreadyCertified' in json) {
    const blobId = json.alreadyCertified.blobId;
    return { blobId, url: blobUrl(blobId), alreadyCertified: true };
  }
  throw new Error(`Unexpected Walrus response: ${JSON.stringify(json)}`);
}

export async function storeFile(path: string, epochs?: number): Promise<StoredBlob> {
  return storeBytes(await readFile(path), epochs);
}

export function blobUrl(blobId: string): string {
  return `${walrusAggregator}/v1/blobs/${blobId}`;
}

// --- publisher response shapes ---------------------------------------------

interface WalrusBlobObject {
  id: string;
  blobId: string;
}
type WalrusStoreResponse =
  | { newlyCreated: { blobObject: WalrusBlobObject } }
  | { alreadyCertified: { blobId: string } };
