/** Env-driven config for the 0G Compute sidecar. Fail loud on missing secrets. */

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

export const depositAmount = () => Number(optional('ZG_DEPOSIT', '0.1'));
export const port = () => Number(optional('ZG_PORT', '8788'));
