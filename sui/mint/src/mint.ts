import { SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { fullnodeUrl, packageId, secretKey } from './config.js';

export interface MintParams {
  name: string;
  song: string;
  artist: string;
  /** Walrus aggregator URL of the image. */
  imageUrl: string;
  walrusBlobId: string;
  provenanceHash: string;
  createdAtMs: number;
  venue: string;
  /** Recipient address; defaults to the minter's own address. */
  recipient?: string;
}

export interface MintResult {
  digest: string;
  objectId: string;
  explorerUrl: string;
}

const enc = new TextEncoder();
const bytes = (s: string) => Array.from(enc.encode(s));

/** Store-agnostic: build, sign and execute the `painting::mint` call. */
export async function mintPainting(p: MintParams): Promise<MintResult> {
  const client = new SuiClient({ url: fullnodeUrl });
  const keypair = Ed25519Keypair.fromSecretKey(secretKey());
  const recipient = p.recipient ?? keypair.toSuiAddress();

  const tx = new Transaction();
  tx.moveCall({
    target: `${packageId()}::painting::mint`,
    arguments: [
      tx.pure.vector('u8', bytes(p.name)),
      tx.pure.vector('u8', bytes(p.song)),
      tx.pure.vector('u8', bytes(p.artist)),
      tx.pure.vector('u8', bytes(p.imageUrl)),
      tx.pure.vector('u8', bytes(p.walrusBlobId)),
      tx.pure.vector('u8', bytes(p.provenanceHash)),
      tx.pure.u64(BigInt(p.createdAtMs)),
      tx.pure.vector('u8', bytes(p.venue)),
      tx.pure.address(recipient),
    ],
  });

  const result = await client.signAndExecuteTransaction({
    signer: keypair,
    transaction: tx,
    options: { showEffects: true, showObjectChanges: true },
  });

  await client.waitForTransaction({ digest: result.digest });

  const created = result.objectChanges?.find(
    (c) => c.type === 'created' && c.objectType.endsWith('::painting::Painting'),
  );
  const objectId =
    created && 'objectId' in created ? created.objectId : '(see transaction)';

  return {
    digest: result.digest,
    objectId,
    explorerUrl: `https://suiscan.xyz/testnet/object/${objectId}`,
  };
}
