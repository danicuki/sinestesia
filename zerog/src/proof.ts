import { appendFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { proofLogPath } from './config.js';

/**
 * Append-only proof ledger. On-chain settlement/verification runs in the
 * background (off the show's hot path), so its result would otherwise be lost to
 * a log line. We persist each settled response as one JSON line here, giving a
 * durable, replayable record we can surface as proof AFTER the performance:
 * which prompt produced which output, on which model/provider, and whether the
 * TEE signature verified — plus the wall-clock timing.
 */
export interface ProofRecord {
  ts: string;
  chatId: string;
  provider: string;
  model: string;
  /** true = TEE signature verified; false = settled but signature check failed. */
  verified: boolean;
  /** ms the background settlement took. */
  settleMs: number;
  /** Present when settlement threw. */
  error?: string;
}

function resolvePath(): string {
  const p = proofLogPath();
  // Relative paths resolve against the package root (one level up from src/).
  return resolve(dirname(fileURLToPath(import.meta.url)), '..', p);
}

export async function appendProof(rec: ProofRecord): Promise<void> {
  try {
    await appendFile(resolvePath(), JSON.stringify(rec) + '\n', 'utf8');
  } catch (err) {
    console.warn(`[0g] proof log write failed: ${(err as Error).message}`);
  }
}
