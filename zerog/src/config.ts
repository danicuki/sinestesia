/** Env-driven config for the 0G Compute sidecar. Fail loud on missing secrets. */
import './load-env.js';

function required(name: string): string {
  const v = process.env[name];
  if (!v || v.trim() === '') throw new Error(`Missing required env ${name} (see .env.example)`);
  return v.trim();
}

function optional(name: string, fallback: string): string {
  const v = process.env[name];
  return v && v.trim() !== '' ? v.trim() : fallback;
}

export const rpcUrl = () => optional('ZG_RPC', 'https://evmrpc-testnet.0g.ai');
export const privateKey = () => required('ZG_PRIVATE_KEY');

/** The verifiable-inference provider address (TEE-sealed). Dynamic on the
 * network — `npm run providers` lists live ones. Default is the live verifiable
 * chat provider (qwen2.5-omni-7b) at time of writing. */
export const providerAddress = () =>
  optional('ZG_PROVIDER', '0xa48f01287233509FD694a22Bf840225062E67836');

/** Optional specific model on a multi-model provider; empty = provider default. */
export const pinnedModel = () => {
  const v = process.env.ZG_MODEL;
  return v && v.trim() !== '' ? v.trim() : undefined;
};

/** Verifiable IMAGE provider (for the bench). Live qwen-image-edit by default;
 * confirm with `npm run providers`. */
export const imageProviderAddress = () =>
  optional('ZG_IMAGE_PROVIDER', '0x4b2a941929E39Adbea5316dDF2B9Bd8Ff3134389');

/** How long to wait for on-chain settlement/verification before returning the
 * answer with `verified: null` and finishing settlement in the background.
 *
 * On-chain settlement is testnet-block latency (seconds), NOT inference latency.
 * For a realtime show you never want to block on it: the default is 0 — return
 * the instant inference completes, always settle in the background. Raise it only
 * if you specifically want the `verified` flag confirmed before responding, and
 * keep it well under the Director's per-call timeout. */
export const verifyTimeoutMs = () => Number(optional('ZG_VERIFY_TIMEOUT_MS', '0'));

/** Where background settlement writes its append-only proof records (JSON lines).
 * Relative paths resolve against the package root. */
export const proofLogPath = () => optional('ZG_PROOF_LOG', 'proofs.jsonl');

/** How much (in 0G) `npm run setup` puts into the ledger.
 *
 * The network requires a minimum of 3 0G to create a ledger, and each provider
 * needs at least 1 0G of locked balance before it will serve. Our old default of
 * 0.1 was far below both, which silently starves verification. */
export const depositAmount = () => Number(optional('ZG_DEPOSIT', '3'));
export const port = () => Number(optional('ZG_PORT', '8788'));
