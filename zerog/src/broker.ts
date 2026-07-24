import { ethers } from 'ethers';
import { createZGComputeNetworkBroker } from '@0gfoundation/0g-compute-ts-sdk';
import { privateKey, providerAddress, rpcUrl, pinnedModel } from './config.js';

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

export interface VerifiedCompletion {
  /** The assistant text. */
  content: string;
  /** Receipt proving where + how this text was computed. */
  receipt: {
    provider: string;
    model: string;
    chatId: string;
    /** true = TEE signature verified; false = returned but unverified; null = verification skipped/errored. */
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

  // Verify the TEE signature (and settle the micro-payment). A false/thrown
  // result means the answer arrived but couldn't be cryptographically tied to
  // the sealed model — we surface that honestly rather than claiming verified.
  let verified: boolean | null = null;
  try {
    // Signature is (providerAddress, chatID, content) in SDK v0.8.
    verified = await broker.inference.processResponse(provider, chatId, content);
  } catch (err) {
    console.warn(`[0g] processResponse: ${(err as Error).message}`);
    verified = false;
  }

  return {
    content,
    receipt: { provider, model, chatId, verified, network: '0g-compute' },
  };
}
