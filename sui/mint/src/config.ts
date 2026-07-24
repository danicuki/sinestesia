import { getFullnodeUrl } from '@mysten/sui/client';
import { fileURLToPath } from 'node:url';

// Populate process.env from sui/mint/.env if it exists, so `npm run mint`/`serve`
// work right after `cp .env.example .env` (no manual `source` needed).
try {
  process.loadEnvFile(fileURLToPath(new URL('../.env', import.meta.url)));
} catch {
  /* no .env file — fall back to the ambient environment */
}

export type Network = 'testnet' | 'devnet' | 'mainnet' | 'localnet';

/** Read an env var, throwing a clear error if a required one is missing. */
function env(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined || v === '') {
    throw new Error(`Missing required env var ${name}. See sui/mint/.env.example`);
  }
  return v;
}

export const network = (process.env.SUI_NETWORK ?? 'testnet') as Network;

export const fullnodeUrl = process.env.SUI_FULLNODE_URL || getFullnodeUrl(network);

/** Published package id of sinestesia_nft (set after `sui client publish`). */
export const packageId = () => env('SUI_PACKAGE_ID');

/** bech32 `suiprivkey1...` secret key of the minting account. */
export const secretKey = () => env('SUI_SECRET_KEY');

/** Public Walrus testnet endpoints by default; override for other networks. */
export const walrusPublisher =
  process.env.WALRUS_PUBLISHER || 'https://publisher.walrus-testnet.walrus.space';
export const walrusAggregator =
  process.env.WALRUS_AGGREGATOR || 'https://aggregator.walrus-testnet.walrus.space';

/** How many Walrus storage epochs to keep the blob. */
export const walrusEpochs = Number(process.env.WALRUS_EPOCHS ?? '5');
