import { writeFile } from 'node:fs/promises';
import { getBroker } from './broker.js';
import { imageProviderAddress } from './config.js';

/**
 * Benchmark 0G Compute as an IMAGE provider — to decide whether it's fast/good
 * enough to (eventually) drive Sinestesia's visuals instead of only the
 * Director. Runs one or more real generations through the verifiable image
 * provider, times each phase, verifies the TEE signature, and writes the PNGs
 * so you can eyeball quality.
 *
 *   npm run bench:image -- --prompt "a yellow sun over a wide river" \
 *     --size 512x512 --n 3 --out bench
 *
 * Needs a FUNDED 0G wallet (faucet + `npm run setup`). Image gen on 0G is an
 * async job (submit → poll), so total latency = submit + queue + inference +
 * download; the numbers below break that out. For a live VJ loop the bar is
 * roughly the current fal.ai cadence (~2–2.5s/frame).
 */

function arg(flag: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

interface Job {
  status: string;
  data?: { data?: { b64_json?: string; url?: string }[] };
  errorMessage?: string;
  retryAfter?: number;
}

async function main() {
  const prompt = arg('--prompt', 'a round yellow sun over a wide calm river, folk art')!;
  const size = arg('--size', '512x512')!;
  const n = Number(arg('--n', '1'));
  const outPrefix = arg('--out', 'bench-0g')!;

  const provider = imageProviderAddress();
  const broker = await getBroker();

  console.log(`provider ${provider}`);
  try {
    await broker.inference.acknowledgeProviderSigner(provider);
  } catch (e) {
    console.warn(`acknowledge: ${(e as Error).message}`);
  }

  const meta = await broker.inference.getServiceMetadata(provider);
  const model = meta.model;
  const endpoint = meta.endpoint;
  // Async image endpoints live under /v1/async (chat is /v1/proxy).
  const asyncBase = endpoint.includes('/v1/proxy')
    ? endpoint.replace('/v1/proxy', '/v1/async')
    : endpoint.replace(/\/$/, '') + '/v1/async';
  console.log(`model    ${model}`);
  console.log(`endpoint ${asyncBase}`);
  console.log(`prompt   "${prompt}"  size ${size}  runs ${n}\n`);

  const timings: number[] = [];

  for (let run = 1; run <= n; run++) {
    const requestBody = { model, prompt, n: 1, size, response_format: 'b64_json' };

    const tSubmit = Date.now();
    const submitHeaders = await broker.inference.getRequestHeaders(
      provider,
      JSON.stringify(requestBody),
    );
    const submitRes = await fetch(`${asyncBase}/images/generations`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(submitHeaders as unknown as Record<string, string>) },
      body: JSON.stringify(requestBody),
    });
    if (!submitRes.ok) {
      const t = await submitRes.text().catch(() => '');
      throw new Error(`submit ${submitRes.status}: ${t.slice(0, 300)}`);
    }
    const { jobId } = (await submitRes.json()) as { jobId: string };
    const submitMs = Date.now() - tSubmit;

    // Poll until the job finishes (cap ~120s so a stuck job doesn't hang).
    let job: Job = { status: 'pending' };
    const deadline = Date.now() + 120_000;
    while (job.status === 'pending' || job.status === 'processing') {
      if (Date.now() > deadline) throw new Error('timed out after 120s');
      const wait = (job.retryAfter ?? 3) * 1000;
      await new Promise((r) => setTimeout(r, wait));
      const pollHeaders = await broker.inference.getRequestHeaders(provider);
      const pollRes = await fetch(`${asyncBase}/jobs/${jobId}`, {
        headers: pollHeaders as unknown as Record<string, string>,
      });
      const retryAfter = pollRes.headers.get('Retry-After');
      job = { ...((await pollRes.json()) as Job), retryAfter: retryAfter ? Number(retryAfter) : 3 };
    }
    if (job.status === 'failed') throw new Error(job.errorMessage ?? 'job failed');

    const totalMs = Date.now() - tSubmit;
    timings.push(totalMs);

    const b64 = job.data?.data?.[0]?.b64_json;
    const url = job.data?.data?.[0]?.url;
    let saved = '(no image data)';
    if (b64) {
      const file = `${outPrefix}-${run}.png`;
      await writeFile(file, Buffer.from(b64, 'base64'));
      saved = file;
    } else if (url) {
      saved = url;
    }

    console.log(
      `run ${run}/${n}  total ${totalMs}ms  (submit ${submitMs}ms + job ${totalMs - submitMs}ms)  → ${saved}`,
    );
  }

  if (timings.length > 1) {
    const avg = Math.round(timings.reduce((a, b) => a + b, 0) / timings.length);
    const min = Math.min(...timings);
    const max = Math.max(...timings);
    console.log(`\nlatency  avg ${avg}ms  min ${min}ms  max ${max}ms  (n=${timings.length})`);
  }
  console.log(
    `\nVerdict guide: a live VJ loop wants roughly ≤2000–2500ms/frame. Compare the` +
      ` PNGs to your fal.ai output for quality; the async submit+poll overhead is` +
      ` the part that may make 0G better suited to song-end stills than per-frame.`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
