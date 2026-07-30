import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import { createRelease } from './paint-and-mint.js';
import { WalrusStorage } from './storage/walrus.js';
import { SuiMinter } from './chains/sui.js';
import type { Performance } from './provenance.js';
import type { Minter } from './chains/types.js';

/**
 * Two commands:
 *
 *   # artist: store image + mint master 1/1 + open the print window
 *   npm run mint -- release --image final.png --performance song.json [--chains sui]
 *
 *   # audience: claim a free open-edition print against a release
 *   npm run mint -- claim --release <releaseRef> [--chain sui] [--to 0xADDR]
 *
 * Storage and chains are pluggable: `--chains sui,evm` releases on both at once.
 */
function arg(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const MINTERS: Record<string, () => Minter> = {
  sui: () => new SuiMinter(),
  // evm: () => new EvmMinter(),  // drop in later — no other change needed
};

function makeMinters(csv: string): Minter[] {
  return csv.split(',').map((c) => c.trim()).map((c) => {
    const make = MINTERS[c];
    if (!make) throw new Error(`Unknown chain "${c}". Known: ${Object.keys(MINTERS).join(', ')}`);
    return make();
  });
}

const command = process.argv[2];

if (command === 'release') {
  const imagePath = arg('--image');
  const perfPath = arg('--performance');
  const chains = arg('--chains') ?? 'sui';
  if (!imagePath || !perfPath) {
    console.error('Usage: npm run mint -- release --image <file> --performance <file.json> [--chains sui]');
    process.exit(1);
  }

  const performance = JSON.parse(await readFile(perfPath, 'utf8')) as Performance;
  const image = await readFile(imagePath);

  console.log(`→ ${basename(imagePath)} → Walrus, release on [${chains}]`);
  const result = await createRelease({
    image,
    performance,
    storage: new WalrusStorage(),
    minters: makeMinters(chains),
  });

  console.log(`  image  ${result.stored.uri}`);
  console.log(`  blobId ${result.stored.id}${result.stored.alreadyExisted ? ' (already stored)' : ''}`);
  console.log(`  proof  sha256 ${result.provenanceHash}`);
  console.log(`  traits ${JSON.stringify(result.traits)}`);
  for (const r of result.releases) {
    console.log(`✓ ${r.chain}: master 1/1 ${r.masterTokenId}`);
    console.log(`    release ${r.releaseRef}  (audience claims prints against this)`);
    console.log(`    tx      ${r.txId}`);
    console.log(`    view    ${r.explorerUrl}`);
  }
} else if (command === 'claim') {
  const releaseRef = arg('--release');
  const chain = arg('--chain') ?? 'sui';
  const to = arg('--to');
  if (!releaseRef) {
    console.error('Usage: npm run mint -- claim --release <releaseRef> [--chain sui] [--to 0xADDR]');
    process.exit(1);
  }
  const [minter] = makeMinters(chain);
  const r = await minter.claimPrint(releaseRef, to);
  console.log(`✓ ${r.chain}: claimed print #${r.edition} ${r.tokenId}`);
  console.log(`    tx   ${r.txId}`);
  console.log(`    view ${r.explorerUrl}`);
} else {
  console.error('Usage: npm run mint -- <release|claim> ...');
  process.exit(1);
}
