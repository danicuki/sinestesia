/** Everything a chain needs to mint a painting, independent of which chain. */
export interface MintRequest {
  name: string;
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
  /** Recipient; each minter defaults to its own signer when omitted. */
  recipient?: string;
  /** Edition number within this song's claim window (1-based), if editioned. */
  edition?: number;
}

export interface MintReceipt {
  chain: string;
  tokenId: string;
  txId: string;
  explorerUrl: string;
}

/** A blockchain that can mint a painting. Add EVM/Solana by implementing this. */
export interface Minter {
  readonly chain: string;
  mint(req: MintRequest): Promise<MintReceipt>;
}
