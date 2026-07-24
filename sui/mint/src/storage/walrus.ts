import { readFile } from 'node:fs/promises';
import { walrusPublisher, walrusAggregator, walrusEpochs } from '../config.js';
import type { Storage, StoredImage } from './types.js';

/**
 * Walrus storage backend. Implements the chain-agnostic `Storage` interface so
 * any minter can reference the resulting URI.
 */
export class WalrusStorage implements Storage {
  readonly name = 'walrus';
  constructor(private epochs: number = walrusEpochs) {}

  async store(bytes: Uint8Array | Buffer): Promise<StoredImage> {
    const res = await fetch(`${walrusPublisher}/v1/blobs?epochs=${this.epochs}`, {
      method: 'PUT',
      body: new Blob([bytes as BlobPart]),
    });
    if (!res.ok) {
      throw new Error(`Walrus store failed: ${res.status} ${await res.text()}`);
    }
    const json = (await res.json()) as WalrusStoreResponse;

    if ('newlyCreated' in json) {
      const id = json.newlyCreated.blobObject.blobId;
      return { id, uri: this.blobUrl(id), backend: this.name, alreadyExisted: false };
    }
    if ('alreadyCertified' in json) {
      const id = json.alreadyCertified.blobId;
      return { id, uri: this.blobUrl(id), backend: this.name, alreadyExisted: true };
    }
    throw new Error(`Unexpected Walrus response: ${JSON.stringify(json)}`);
  }

  async storeFile(path: string): Promise<StoredImage> {
    return this.store(await readFile(path));
  }

  blobUrl(blobId: string): string {
    return `${walrusAggregator}/v1/blobs/${blobId}`;
  }
}

interface WalrusBlobObject {
  id: string;
  blobId: string;
}
type WalrusStoreResponse =
  | { newlyCreated: { blobObject: WalrusBlobObject } }
  | { alreadyCertified: { blobId: string } };
