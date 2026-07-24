import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';
import { storeFile } from './walrus.js';
import { provenanceHash, type Performance } from './provenance.js';
import { mintPainting } from './mint.js';

/**
 * End-to-end: take the final canvas image + the performance record, store the
 * image on Walrus, hash the performance, and mint the NFT.
 *
 *   npm run mint -- --image final.png --performance song.json [--to 0xADDR]
 *
 * The performance JSON matches the `Performance` interface in provenance.ts.
 */
function arg(flag: string): string | undefined {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const imagePath = arg('--image');
const perfPath = arg('--performance');
const recipient = arg('--to');

if (!imagePath || !perfPath) {
  console.error(
    'Usage: npm run mint -- --image <file> --performance <file.json> [--to <0xaddr>]',
  );
  process.exit(1);
}

const perf = JSON.parse(await readFile(perfPath, 'utf8')) as Performance;

console.log(`→ storing ${basename(imagePath)} on Walrus…`);
const blob = await storeFile(imagePath);
console.log(`  blobId ${blob.blobId}${blob.alreadyCertified ? ' (already stored)' : ''}`);
console.log(`  url    ${blob.url}`);

const hash = provenanceHash(perf);
console.log(`→ provenance sha256 ${hash}`);

console.log('→ minting on Sui…');
const res = await mintPainting({
  name: `Sinestesia — ${perf.song}`,
  song: perf.song,
  artist: perf.artist,
  imageUrl: blob.url,
  walrusBlobId: blob.blobId,
  provenanceHash: hash,
  createdAtMs: perf.endedAtMs,
  venue: perf.venue,
  recipient,
});

console.log(`✓ minted Painting`);
console.log(`  object ${res.objectId}`);
console.log(`  tx     ${res.digest}`);
console.log(`  view   ${res.explorerUrl}`);
