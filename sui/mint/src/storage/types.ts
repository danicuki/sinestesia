/** Where the painting's bytes live. Chain-agnostic: Walrus today, IPFS/Arweave
 *  tomorrow. Storage happens once; every chain references the same URI. */
export interface StoredImage {
  /** Public URL to read the bytes back. */
  uri: string;
  /** Backend-native content id (Walrus blobId, IPFS CID, …). */
  id: string;
  /** Which backend produced this (for the NFT metadata + audits). */
  backend: string;
  /** true if identical bytes already existed (no new cost). */
  alreadyExisted: boolean;
}

export interface Storage {
  readonly name: string;
  store(bytes: Uint8Array | Buffer): Promise<StoredImage>;
}
