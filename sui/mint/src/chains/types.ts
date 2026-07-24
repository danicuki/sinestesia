/** Everything a chain needs to create a release, independent of which chain. */
export interface MintRequest {
  song: string;
  artist: string;
  venue: string;
  /** Public image URL (from a Storage backend). */
  imageUri: string;
  /** Backend-native content id (Walrus blobId, IPFS CID, …). */
  imageStorageId: string;
  /** Which storage backend holds the image. */
  storageBackend: string;
  /** SHA-256 binding the token to the exact live performance. */
  provenanceHash: string;
  /** Unix ms when the performance ended. */
  createdAtMs: number;
  /** Derived rarity traits (see traits.ts). */
  traits: Record<string, string | number>;
}

/** Result of creating a release: the master 1/1 plus the shared release ref
 *  audience members claim prints against. */
export interface ReleaseReceipt {
  chain: string;
  /** Chain-native id of the shared release (Sui object id, EVM contract, …). */
  releaseRef: string;
  /** The master 1/1 token id. */
  masterTokenId: string;
  txId: string;
  explorerUrl: string;
}

/** Result of an audience member claiming an open-edition print. */
export interface PrintReceipt {
  chain: string;
  tokenId: string;
  edition: number;
  txId: string;
  explorerUrl: string;
}

/**
 * A blockchain that can mint Sinestesia paintings. Two operations:
 *  - createRelease: artist mints the master 1/1 and opens the print window;
 *  - claimPrint: anyone mints a free open-edition print to `recipient`.
 * Add EVM/Solana by implementing this — nothing else changes.
 */
export interface Minter {
  readonly chain: string;
  createRelease(req: MintRequest): Promise<ReleaseReceipt>;
  claimPrint(releaseRef: string, recipient?: string): Promise<PrintReceipt>;
}
