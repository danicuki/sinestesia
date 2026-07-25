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
  await handleRequest(req, res);
}
