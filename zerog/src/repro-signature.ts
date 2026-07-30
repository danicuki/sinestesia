import { ethers } from 'ethers';
import { getBroker, getService } from './broker.js';
import { privateKey, providerAddress, rpcUrl } from './config.js';

/**
 * End-to-end check of 0G verifiable inference:
 *
 *   npm run repro:signature
 *
 * Written to chase what looked like a provider bug — signature retrieval failing
 * with `chat_id_not_found` for an id the provider had just issued. It wasn't a
 * provider bug. The verifiable chat id is the one in the ZG-Res-Key response
 * header; the body's `id` is that same uuid prefixed with "chatcmpl-", and the
 * provider's broker doesn't recognise it. We were verifying with the body id.
 *
 * Kept as a diagnostic: it drives account, provider record, inference, raw
 * signature retrieval and processResponse separately, so if verification ever
 * fails again the failing step is obvious rather than inferred.
 */

const line = (s = '') => console.log(s);
const rule = () => line('─'.repeat(72));

async function main() {
  line();
  rule();
  line('0G verifiable inference — signature retrieval reproduction');
  rule();

  const wallet = new ethers.Wallet(privateKey(), new ethers.JsonRpcProvider(rpcUrl()));
  const broker = await getBroker();
  const addr = providerAddress();

  // ── 1. Account/ledger state, so "unfunded account" is ruled out ────────────
  line();
  line('1. ACCOUNT');
  line(`   wallet    ${wallet.address}`);
  try {
    const ledger = await broker.ledger.getLedger();
    const json = JSON.stringify(ledger, (_k, v) => (typeof v === 'bigint' ? v.toString() : v));
    line(`   ledger    ${json}`);
  } catch (err) {
    line(`   ledger    UNAVAILABLE (${(err as Error).message})`);
  }

  // ── 2. The provider's own on-chain record ─────────────────────────────────
  const services = (await broker.inference.listService()) as unknown as any[];
  const svc = services.find(
    (s) => String(s[0] ?? '').toLowerCase() === addr.toLowerCase(),
  );
  line();
  line('2. PROVIDER (on-chain service record)');
  if (!svc) {
    line(`   provider ${addr} NOT FOUND in listService()`);
    return;
  }
  const [, kind, url, , , , model, verifiability, additionalInfo, teeSigner, acked] = svc;
  line(`   address        ${addr}`);
  line(`   type           ${kind}`);
  line(`   url            ${url}`);
  line(`   model          ${model}`);
  line(`   verifiability  ${verifiability}      <- TeeML = responses should be signed`);
  line(`   teeSigner      ${teeSigner}`);
  line(`   acknowledged   ${acked}`);
  line(`   additionalInfo ${additionalInfo}`);

  // ── 3. Inference: this half works ─────────────────────────────────────────
  const meta = await getService();
  const messages = [{ role: 'user', content: 'One vivid phrase for a drum fill.' }];

  line();
  line('3. INFERENCE  (POST {endpoint}/chat/completions)');
  const t0 = Date.now();
  const headers = await broker.inference.getRequestHeaders(meta.provider, messages[0]!.content);
  const tSigned = Date.now();
  const res = await fetch(`${meta.endpoint}/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(headers as any) },
    body: JSON.stringify({ model: meta.model, messages, max_tokens: 30 }),
  });
  if (!res.ok) {
    line(`   FAILED ${res.status}: ${(await res.text()).slice(0, 300)}`);
    return;
  }
  const body: any = await res.json();
  // The docs are explicit: take the chat id from the ZG-Res-Key response header
  // FIRST, and only fall back to the body id. They are different values — the
  // body id is the OpenAI-style completion id, which the provider's broker does
  // not know, so verifying with it fails as chat_id_not_found. Our app used the
  // body id, which is what produced the failure this script was written to chase.
  const headerId: string =
    res.headers.get('ZG-Res-Key') ?? res.headers.get('zg-res-key') ?? '';
  const bodyId: string = body.id ?? '';
  const chatId: string = headerId || bodyId;
  const content: string = body.choices?.[0]?.message?.content ?? '';
  line(`   signing headers  ${tSigned - t0}ms`);
  line(`   inference        ${Date.now() - tSigned}ms   => HTTP 200 OK`);
  line(`   ZG-Res-Key hdr   ${headerId || '(absent)'}   <- the verifiable id`);
  line(`   body id          ${bodyId}   <- OpenAI completion id, NOT verifiable`);
  line(`   using            ${chatId}`);
  line(`   usage            ${JSON.stringify(body.usage)}`);
  line(`   content          "${content.slice(0, 80)}"`);

  // ── 4. Verification: this half fails ──────────────────────────────────────
  // The SDK's Verifier.fetchSignatureByChatID hits exactly this URL.
  const sigUrl = `${url}/v1/proxy/signature/${chatId}?model=${meta.model}`;
  line();
  line('4. SIGNATURE RETRIEVAL  (GET, what the SDK calls internally)');
  line(`   ${sigUrl}`);

  const attempts = [0, 2000, 5000];
  for (const wait of attempts) {
    if (wait) await new Promise((r) => setTimeout(r, wait));
    const r = await fetch(sigUrl, { headers: { 'Content-Type': 'application/json' } });
    const text = (await r.text()).slice(0, 200);
    line(`   +${String(wait).padStart(4)}ms  HTTP ${r.status}  ${text}`);
  }

  // ── 5. What the SDK concludes ─────────────────────────────────────────────
  let verified: boolean | null = null;
  line();
  line('5. SDK processResponse()');
  try {
    const ok = await broker.inference.processResponse(meta.provider, chatId);
    line(`   => ${ok}`);
    verified = ok;
  } catch (err) {
    line(`   => THREW: ${(err as Error).message}`);
  }

  // Report what actually happened. An earlier version of this script printed a
  // fixed conclusion, which kept asserting a provider bug after the real cause
  // (our own chat-id extraction) was fixed — a repro that can't change its mind
  // is worse than no repro.
  line();
  rule();
  if (verified === true) {
    line('RESULT: verification SUCCEEDS end to end.');
    line(`        The verifiable id is the ZG-Res-Key header (${headerId || 'n/a'}).`);
    line('        The body id is that same uuid prefixed with "chatcmpl-", and the');
    line('        provider does not recognise it — using it yields chat_id_not_found.');
  } else if (verified === false) {
    line('RESULT: signature retrieved, but processResponse returned false.');
    line('        Check: TEE signer acknowledged, service still verifiable, and that');
    line('        the id used came from ZG-Res-Key rather than the response body.');
  } else {
    line('RESULT: verification did not complete (null/threw). See steps 4-5 above.');
  }
  rule();
  line();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
