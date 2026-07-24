import { createServer } from 'node:http';
import { getService, verifiedChat } from './broker.js';
import { port, providerAddress } from './config.js';

/**
 * Minimal OpenAI-compatible sidecar in front of 0G Compute.
 *
 * The Elixir Director POSTs a normal chat-completion body to
 * `POST /v1/chat/completions`; we run it through the 0G broker (signed request +
 * TEE verification) and return an OpenAI-shaped response with an extra
 * `verification` object — the receipt the show surfaces on screen.
 *
 *   GET  /healthz               → broker/provider/model status
 *   POST /v1/chat/completions   → { choices, verification }
 */

function json(res: import('node:http').ServerResponse, status: number, body: unknown) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(payload);
}

async function readBody(req: import('node:http').IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString('utf8');
}

/** The string 0G signs/bills against: the last user line (its single-turn unit). */
function lastUserContent(messages: { role: string; content: string }[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m && m.role === 'user') return m.content;
  }
  return messages.map((m) => m.content).join('\n');
}

const server = createServer((req, res) => {
  void (async () => {
    try {
      if (req.method === 'GET' && req.url === '/healthz') {
        const svc = await getService();
        return json(res, 200, { ok: true, ...svc });
      }

      if (req.method === 'POST' && req.url === '/v1/chat/completions') {
        const raw = await readBody(req);
        const body = JSON.parse(raw) as {
          messages?: { role: string; content: string }[];
          temperature?: number;
          max_tokens?: number;
        };
        const messages = body.messages ?? [];
        if (messages.length === 0) return json(res, 400, { error: 'messages required' });

        const { content, receipt } = await verifiedChat(messages, lastUserContent(messages), {
          temperature: body.temperature,
          maxTokens: body.max_tokens,
        });

        // OpenAI-compatible shape + our verification receipt.
        return json(res, 200, {
          id: receipt.chatId,
          object: 'chat.completion',
          model: receipt.model,
          choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }],
          verification: receipt,
        });
      }

      json(res, 404, { error: 'not found' });
    } catch (err) {
      console.error('[0g] request failed:', err);
      json(res, 502, { error: (err as Error).message });
    }
  })();
});

const p = port();
server.listen(p, () => {
  console.log(`[0g] sidecar on http://127.0.0.1:${p}`);
  console.log(`[0g] provider ${providerAddress()}`);
  console.log(`[0g] warming up broker…`);
  // Warm the broker/metadata so the first Director call isn't slow.
  getService()
    .then((s) => console.log(`[0g] ready — model ${s.model} @ ${s.endpoint}`))
    .catch((e) => console.warn(`[0g] warmup failed (will retry on first request): ${e.message}`));
});
