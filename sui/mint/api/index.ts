import type { IncomingMessage, ServerResponse } from 'node:http';
import { handleRequest } from '../src/server.js';

/**
 * Serverless entry point for the public claim app.
 *
 * `vercel.json` rewrites every path here, so the deployment exposes exactly the
 * same routes as the local sidecar — /claim (the QR target), /certificate,
 * /provenance/:blob and /img/:blob — from the same source, not a fork.
 *
 * Only the audience-facing routes matter here. `POST /release` (composing the
 * animation) stays on the show laptop: it needs the frames and heavy image
 * tooling, and nothing public should be able to trigger a release.
 */
export default async function handler(req: IncomingMessage, res: ServerResponse) {
  try {
    await handleRequest(req, res);
  } catch (err) {
    // Anything escaping the router would otherwise surface as Vercel's opaque
    // FUNCTION_INVOCATION_FAILED page, which says nothing about what broke.
    // Answer with the message instead: this sidecar gets debugged from the
    // backend's error string far more often than from the dashboard.
    console.error('[mint] unhandled:', err);
    if (!res.headersSent) {
      res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: (err as Error).message }));
    }
  }
}
