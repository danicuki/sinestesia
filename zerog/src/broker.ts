import { ethers } from 'ethers';
import { createZGComputeNetworkBroker } from '@0gfoundation/0g-compute-ts-sdk';
import { privateKey, providerAddress, rpcUrl, pinnedModel, verifyTimeoutMs } from './config.js';
import { appendProof } from './proof.js';

/**
 * Thin wrapper over the 0G broker. Initializes once, acknowledges the provider,
 * caches the OpenAI-compatible endpoint + model, and exposes the two per-request
 * primitives the sidecar needs: signed headers and response verification.
 *
 * The broker is what makes inference *verifiable*: `getRequestHeaders` signs
 * each call against the on-chain ledger, and `processResponse` checks the TEE
 * (TeeML) signature the provider returns, so we can prove a given Director
 * prompt was produced by the exact model in a sealed enclave — not swapped out.
 */
export type Broker = Awaited<ReturnType<typeof createZGComputeNetworkBroker>>;

export interface ServiceInfo {
  endpoint: string;
  model: string;
  provider: string;
}

let brokerPromise: Promise<Broker> | null = null;
let service: ServiceInfo | null = null;

export async function getBroker(): Promise<Broker> {
  if (!brokerPromise) {
    const provider = new ethers.JsonRpcProvider(rpcUrl());
    const wallet = new ethers.Wallet(privateKey(), provider);
    // The SDK bundles its own ethers copy, so its `Wallet` is nominally a
    // different type than ours even though they're the same version — cast.
    brokerPromise = createZGComputeNetworkBroker(
      wallet as unknown as Parameters<typeof createZGComputeNetworkBroker>[0],
    );
  }
  return brokerPromise;
}

/** Acknowledge the provider (idempotent) and cache its endpoint + model. */
export async function getService(): Promise<ServiceInfo> {
  if (service) return service;
  const broker = await getBroker();
  const addr = providerAddress();

  // Acknowledging the provider's TEE signer is a one-time on-chain step; if it
  // was already done in a previous run the call is a no-op that may throw —
  // swallow that so the sidecar still boots.
  try {
    await broker.inference.acknowledgeProviderSigner(addr);
  } catch (err) {
    console.warn(`[0g] acknowledgeProviderSigner: ${(err as Error).message}`);
  }

  // getServiceMetadata returns the provider's *default* model; a pinned model
  // (multi-model provider) is applied by overriding `model` in the request body.
  const meta = await broker.inference.getServiceMetadata(addr);
  service = { endpoint: meta.endpoint, model: pinnedModel() ?? meta.model, provider: addr };
  return service;
}

/**
 * Prime the broker, provider metadata, AND the request-signing path so the first
 * real Director call runs on the warm (~1.7s) path instead of the cold (~2.8s)
 * one. `getRequestHeaders` has a one-time cold cost (nonce/account state); we pay
 * it here at boot with a throwaway signature rather than during the show.
 */
export async function warmup(): Promise<ServiceInfo> {
  const svc = await getService();
  const broker = await getBroker();
  try {
    await broker.inference.getRequestHeaders(svc.provider, 'warmup');
  } catch (err) {
    console.warn(`[0g] signing warmup skipped: ${(err as Error).message}`);
  }
  return svc;
}

export interface VerifiedCompletion {
  /** The assistant text. */
  content: string;
  /** Receipt proving where + how this text was computed. */
  receipt: {
    provider: string;
    model: string;
    chatId: string;
    /** true = TEE signature verified; false = returned but unverified; null = settlement still pending (didn't confirm within ZG_VERIFY_TIMEOUT_MS; finishing in the background). */
    verified: boolean | null;
    network: '0g-compute';
  };
}

/**
 * Run one chat completion through 0G and verify it. `messages` is the standard
 * OpenAI array; `signContent` is the string the ledger signs/bills against
 * (the user's line — matches 0G's single-turn billing model).
 */
export async function verifiedChat(
  messages: { role: string; content: string }[],
  signContent: string,
  opts: { temperature?: number; maxTokens?: number } = {},
): Promise<VerifiedCompletion> {
  const broker = await getBroker();
  const { endpoint, model, provider } = await getService();

  const headers = await broker.inference.getRequestHeaders(provider, signContent);

  const res = await fetch(`${endpoint}/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(headers as unknown as Record<string, string>),
    },
    body: JSON.stringify({
      model,
      messages,
      temperature: opts.temperature ?? 0.8,
      max_tokens: opts.maxTokens ?? 100,
    }),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`0g provider ${res.status}: ${text.slice(0, 300)}`);
  }

  const json = (await res.json()) as {
    id?: string;
    choices?: { message?: { content?: string } }[];
  };
  const content = json.choices?.[0]?.message?.content ?? '';
  const chatId = json.id ?? '';

  // Verify the TEE signature (and settle the micro-payment). This step sends an
  // on-chain settlement tx, which on testnet can take longer than the Director's
  // whole request budget — so we must NOT let it block the response. We race it
  // against a short window: if the chain answers in time we attach the real
  // verified flag; otherwise we return `null` (verification pending) and let the
  // settlement finish in the background. Either way the show gets its text fast.
  //
  // A false/thrown result means the answer arrived but couldn't be
  // cryptographically tied to the sealed model — surfaced honestly, not as
  // "verified". `null` means "not yet confirmed", distinct from `false`.
  // Every settlement — whether or not the hot path waited for it — is persisted
  // to the proof log so we have durable, replayable proof after the show.
  const settleStart = Date.now();
  const settle: Promise<boolean> = broker.inference
    // Signature is (providerAddress, chatID, content) in SDK v0.8.
    .processResponse(provider, chatId, content)
    .then((ok) => {
      const verifiedOk = Boolean(ok);
      void appendProof({
        ts: new Date().toISOString(),
        chatId,
        provider,
        model,
        verified: verifiedOk,
        settleMs: Date.now() - settleStart,
      });
      return verifiedOk;
    })
    .catch((err) => {
      console.warn(`[0g] processResponse: ${(err as Error).message}`);
      void appendProof({
        ts: new Date().toISOString(),
        chatId,
        provider,
        model,
        verified: false,
        settleMs: Date.now() - settleStart,
        error: (err as Error).message,
      });
      return false;
    });

  let verified: boolean | null = null;
  const window = verifyTimeoutMs();
  if (window <= 0) {
    // Realtime default: never block on the chain. Settle in the background.
    void settle.then((ok) =>
      console.log(`[0g] settlement landed (verified=${ok}) chatId=${chatId}`),
    );
  } else {
    // Wait up to `window` ms for confirmation; otherwise return pending (null)
    // and let settlement finish in the background.
    const pending = Symbol('pending');
    const raced = await Promise.race([
      settle,
      new Promise<typeof pending>((resolve) => setTimeout(() => resolve(pending), window)),
    ]);
    if (raced === pending) {
      void settle.then((ok) =>
        console.log(`[0g] settlement landed (verified=${ok}) chatId=${chatId}`),
      );
    } else {
      verified = raced;
    }
  }

  return {
    content,
    receipt: { provider, model, chatId, verified, network: '0g-compute' },
  };
}
