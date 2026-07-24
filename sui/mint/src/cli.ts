import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import { paintAndMint } from './paint-and-mint.js';
import { WalrusStorage } from './storage/walrus.js';
import { SuiMinter } from './chains/sui.js';
import type { Performance } from './provenance.js';
import type { Minter } from './chains/types.js';

/**
 *   npm run mint -- --image final.png --performance song.json [--to 0xADDR] [--chains sui]
 *
 * Storage and chains are pluggable: `--chains sui,evm` would mint the same
 * painting to several chains once their minters exist.
 */
function arg(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const imagePath = arg('--image');
const perfPath = arg('--performance');
const recipient = arg('--to');
const chains = (arg('--chains') ?? 'sui').split(',').map((c) => c.trim());

if (!imagePath || !perfPath) {
  console.error(
    'Usage: npm run mint -- --image <file> --performance <file.json> [--to <0xaddr>] [--chains sui]',
  );
  process.exit(1);
}

const MINTERS: Record<string, () => Minter> = {
  sui: () => new SuiMinter(),
  // evm: () => new EvmMinter(),  // drop in later — no other change needed
};

const minters = chains.map((c) => {
  const make = MINTERS[c];
  if (!make) throw new Error(`Unknown chain "${c}". Known: ${Object.keys(MINTERS).join(', ')}`);
  return make();
});

const performance = JSON.parse(await readFile(perfPath, 'utf8')) as Performance;
const image = await readFile(imagePath);

console.log(`→ ${basename(imagePath)} → Walrus, mint to [${chains.join(', ')}]`);
const result = await paintAndMint({
  image,
  performance,
  storage: new WalrusStorage(),
  minters,
  recipient,
});

console.log(`  image    ${result.stored.uri}`);
console.log(`  blobId   ${result.stored.id}${result.stored.alreadyExisted ? ' (already stored)' : ''}`);
console.log(`  proof    sha256 ${result.provenanceHash}`);
console.log(`  traits   ${JSON.stringify(result.traits)}`);
for (const r of result.receipts) {
  console.log(`✓ ${r.chain}: token ${r.tokenId}`);
  console.log(`    tx   ${r.txId}`);
  console.log(`    view ${r.explorerUrl}`);
}
