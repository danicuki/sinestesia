import { SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { fullnodeUrl, packageId, secretKey } from '../config.js';
import type { Minter, MintRequest, MintReceipt } from './types.js';

const enc = new TextEncoder();
const bytes = (s: string) => Array.from(enc.encode(s));

/** Sui implementation of the chain-agnostic `Minter` interface. */
export class SuiMinter implements Minter {
  readonly chain = 'sui';
  private client = new SuiClient({ url: fullnodeUrl });
  private keypair = Ed25519Keypair.fromSecretKey(secretKey());

  async mint(req: MintRequest): Promise<MintReceipt> {
    const recipient = req.recipient ?? this.keypair.toSuiAddress();

    const tx = new Transaction();
    tx.moveCall({
      target: `${packageId()}::painting::mint`,
      arguments: [
        tx.pure.vector('u8', bytes(req.name)),
        tx.pure.vector('u8', bytes(req.song)),
        tx.pure.vector('u8', bytes(req.artist)),
        tx.pure.vector('u8', bytes(req.imageUri)),
        tx.pure.vector('u8', bytes(req.imageStorageId)),
        tx.pure.vector('u8', bytes(req.provenanceHash)),
        tx.pure.u64(BigInt(req.createdAtMs)),
        tx.pure.vector('u8', bytes(req.venue)),
        tx.pure.address(recipient),
      ],
    });

    const result = await this.client.signAndExecuteTransaction({
      signer: this.keypair,
      transaction: tx,
      options: { showEffects: true, showObjectChanges: true },
    });
    await this.client.waitForTransaction({ digest: result.digest });

    const created = result.objectChanges?.find(
      (c) => c.type === 'created' && c.objectType.endsWith('::painting::Painting'),
    );
    const tokenId = created && 'objectId' in created ? created.objectId : '(see tx)';

    return {
      chain: this.chain,
      tokenId,
      txId: result.digest,
      explorerUrl: `https://suiscan.xyz/testnet/object/${tokenId}`,
    };
  }
}
