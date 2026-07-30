/**
 * Minimal, zero-dependency `.env` loader. Node <20 has no `--env-file`, and we
 * don't want a dotenv dependency for one sidecar. Import this for its side effect
 * (`import './load-env.js';`) before anything reads `process.env`.
 *
 * Existing environment variables always win over the file, so shell overrides and
 * CI secrets keep priority. Missing file is a no-op.
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

function loadEnv() {
  // .env lives at the package root, one level up from src/.
  const envPath = resolve(dirname(fileURLToPath(import.meta.url)), '..', '.env');

  let raw: string;
  try {
    raw = readFileSync(envPath, 'utf8');
  } catch {
    return; // No .env — rely on the real environment.
  }

  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;

    const key = trimmed.slice(0, eq).trim();
    if (!key || key in process.env) continue; // Real env wins.

    let value = trimmed.slice(eq + 1).trim();
    // Strip matching surrounding quotes.
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

loadEnv();
