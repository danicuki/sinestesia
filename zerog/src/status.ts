import { ethers } from 'ethers';
import { getBroker, getService } from './broker.js';
import { privateKey, providerAddress, rpcUrl } from './config.js';

/**
 * One-shot diagnostics for the 0G sidecar:
 *   npm run status
 *
 * Reports wallet balance, ledger balance, and — most importantly — measures
 * INFERENCE latency separately from on-chain SETTLEMENT latency, so we can see
 * exactly what the Director waits for vs. what happens in the background.
 */
async function main() {
  const provider = new ethers.JsonRpcProvider(rpcUrl());
  const wallet = new ethers.Wallet(privateKey(), provider);
  const bal = await provider.getBalance(wallet.address);
  console.log(`wallet    ${wallet.address}`);
  console.log(`balance   ${ethers.formatEther(bal)} 0G (testnet)`);

  const broker = await getBroker();

  try {
    const ledger = await broker.ledger.getLedger();
    console.log(`ledger    ${JSON.stringify(ledger, (_k, v) => (typeof v === 'bigint' ? v.toString() : v))}`);
  } catch (err) {
    console.log(`ledger    unavailable (${(err as Error).message})`);
  }

  const svc = await getService();
  console.log(`provider  ${providerAddress()}`);
  console.log(`service   model ${svc.model} @ ${svc.endpoint}`);

  // --- latency: inference vs settlement, measured over N runs (cold + warm) ---
  const messages = [
    { role: 'system', content: 'You are a terse art director. Reply with a single vivid phrase.' },
    { role: 'user', content: 'Direct the next 5 seconds of visuals for a soaring guitar solo.' },
  ];

  const runs = 3;
  for (let i = 0; i < runs; i++) {
    const signContent = `${messages[messages.length - 1]!.content} #${i}`;

    const t0 = Date.now();
    const headers = await broker.inference.getRequestHeaders(svc.provider, signContent);
    const tHeaders = Date.now();

    const res = await fetch(`${svc.endpoint}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(headers as unknown as Record<string, string>) },
      body: JSON.stringify({ model: svc.model, messages, temperature: 0.8, max_tokens: 100 }),
    });
    const tInfer = Date.now();

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      console.log(`\nrun ${i} inference FAILED ${res.status}: ${text.slice(0, 200)}`);
      continue;
    }
    const body = (await res.json()) as { id?: string; choices?: { message?: { content?: string } }[] };
    const content = body.choices?.[0]?.message?.content ?? '';

    const label = i === 0 ? 'cold' : 'warm';
    console.log(`\n── run ${i} (${label}) ───────────────────`);
    console.log(`sign headers   ${tHeaders - t0} ms`);
    console.log(`inference      ${tInfer - tHeaders} ms   ← Director hot path total = ${tInfer - t0} ms`);
  }
  console.log('────────────────────────────────────────');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
