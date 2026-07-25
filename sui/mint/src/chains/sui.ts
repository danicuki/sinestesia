import { SuiClient } from '@mysten/sui/client';
import { decodeSuiPrivateKey } from '@mysten/sui/cryptography';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Secp256k1Keypair } from '@mysten/sui/keypairs/secp256k1';
import { Secp256r1Keypair } from '@mysten/sui/keypairs/secp256r1';
import type { Keypair } from '@mysten/sui/cryptography';
import { Transaction } from '@mysten/sui/transactions';
import { fullnodeUrl, packageId, secretKey } from '../config.js';
import type { Minter, MintRequest, ReleaseReceipt, PrintReceipt } from './types.js';

const enc = new TextEncoder();
const bytes = (s: string) => Array.from(enc.encode(s));
const explorer = (kind: 'object' | 'tx', id: string) =>
  `https://suiscan.xyz/testnet/${kind === 'object' ? 'object' : 'tx'}/${id}`;

/**
 * Build the right keypair for the given `suiprivkey1…` secret. The bech32 string
 * encodes its signature scheme, and each keypair class only accepts its own —
 * `Ed25519Keypair.fromSecretKey` throws on a Secp256k1 key. Decode the scheme
 * and construct the matching class so any valid Sui key (ed25519 / secp256k1 /
 * secp256r1) works.
 */
function keypairFromSecret(secret: string): Keypair {
  const { schema } = decodeSuiPrivateKey(secret);
  switch (schema) {
    case 'ED25519':
      return Ed25519Keypair.fromSecretKey(secret);
    case 'Secp256k1':
      return Secp256k1Keypair.fromSecretKey(secret);
    case 'Secp256r1':
      return Secp256r1Keypair.fromSecretKey(secret);
    default:
      throw new Error(`Unsupported Sui key scheme: ${schema}`);
  }
}

/** Sui implementation of the chain-agnostic `Minter` interface. */
export class SuiMinter implements Minter {
  readonly chain = 'sui';
  private client = new SuiClient({ url: fullnodeUrl });
  private keypair = keypairFromSecret(secretKey());

  /** Artist mints the master 1/1 and shares the Release for print claims. */
  async createRelease(req: MintRequest): Promise<ReleaseReceipt> {
    const tx = new Transaction();
    tx.moveCall({
      target: `${packageId()}::painting::create_release`,
      arguments: [
        tx.pure.vector('u8', bytes(req.song)),
        tx.pure.vector('u8', bytes(req.artist)),
        tx.pure.vector('u8', bytes(req.venue)),
        tx.pure.vector('u8', bytes(req.imageUri)),
        tx.pure.vector('u8', bytes(req.imageStorageId)),
        tx.pure.vector('u8', bytes(req.provenanceHash)),
        tx.pure.vector('u8', bytes(JSON.stringify(req.traits))),
        tx.pure.u64(BigInt(req.createdAtMs)),
      ],
    });

    const result = await this.exec(tx);
    const changes = result.objectChanges ?? [];

    const master = changes.find(
      (c) => c.type === 'created' && c.objectType.endsWith('::painting::Painting'),
    );
    const release = changes.find(
      (c) => c.type === 'created' && c.objectType.endsWith('::painting::Release'),
    );
    const masterTokenId = master && 'objectId' in master ? master.objectId : '(see tx)';
    const releaseRef = release && 'objectId' in release ? release.objectId : '(see tx)';

    return {
      chain: this.chain,
      releaseRef,
      masterTokenId,
      txId: result.digest,
      explorerUrl: explorer('object', releaseRef),
    };
  }

  /** Anyone claims a free open-edition print (pays only gas). */
  async claimPrint(releaseRef: string, recipient?: string): Promise<PrintReceipt> {
    const tx = new Transaction();
    tx.moveCall({
      target: `${packageId()}::painting::claim_print`,
      arguments: [tx.object(releaseRef)],
    });
    if (recipient) tx.setSender(recipient); // wallet flow; here we sign as self

    const result = await this.exec(tx);
    const print = (result.objectChanges ?? []).find(
      (c) => c.type === 'created' && c.objectType.endsWith('::painting::Painting'),
    );
    const tokenId = print && 'objectId' in print ? print.objectId : '(see tx)';

    const edition = this.editionFromEvents(result);
    return {
      chain: this.chain,
      tokenId,
      edition,
      txId: result.digest,
      explorerUrl: explorer('object', tokenId),
    };
  }

  /**
   * Read a Release's on-chain fields. This is the authoritative side of the
   * certificate: everything shown to a viewer is checked against what is
   * actually stored on Sui, not against what our own server remembers.
   */
  async getRelease(releaseRef: string): Promise<Record<string, unknown> | null> {
    const obj = await this.client.getObject({ id: releaseRef, options: { showContent: true } });
    const content = obj.data?.content;
    if (!content || content.dataType !== 'moveObject') return null;
    return content.fields as Record<string, unknown>;
  }

  private async exec(tx: Transaction) {
    const result = await this.client.signAndExecuteTransaction({
      signer: this.keypair,
      transaction: tx,
      options: { showEffects: true, showObjectChanges: true, showEvents: true },
    });
    await this.client.waitForTransaction({ digest: result.digest });
    return result;
  }

  private editionFromEvents(result: { events?: { parsedJson?: unknown }[] | null }): number {
    const ev = result.events?.find(
      (e) => (e.parsedJson as { edition?: unknown } | undefined)?.edition !== undefined,
    );
    const raw = (ev?.parsedJson as { edition?: string | number } | undefined)?.edition;
    return raw === undefined ? 0 : Number(raw);
  }
}
