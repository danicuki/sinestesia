import { getFullnodeUrl } from '@mysten/sui/client';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';

// Populate process.env from sui/mint/.env if it exists, so `npm run mint`/`serve`
// work right after `cp .env.example .env` (no manual `source` needed).
//
// `process.loadEnvFile` only exists on Node >=20.6, and npm may run under an
// older nvm-default Node — there, that call throws and (previously) got swallowed
// as "no .env", leaving every secret unset. So we prefer it when available but
// fall back to a tiny hand parser. Only a genuinely missing file is silent;
// existing-env vars always win so shell overrides keep priority.
(function loadEnv() {
  const envPath = fileURLToPath(new URL('../.env', import.meta.url));
  if (typeof process.loadEnvFile === 'function') {
    try {
      process.loadEnvFile(envPath);
      return;
    } catch {
      /* no .env file — fall back to the ambient environment */
      return;
    }
  }
  // Node <20.6: parse the file ourselves.
  let raw: string;
  try {
    raw = readFileSync(envPath, 'utf8');
  } catch {
    return; // No .env — use the ambient environment.
  }
  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    if (!key || key in process.env) continue; // Real env wins.
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
})();

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
