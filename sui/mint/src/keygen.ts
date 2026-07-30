import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { getFaucetHost, requestSuiFromFaucetV2 } from '@mysten/sui/faucet';
import { network } from './config.js';

/**
 * Generate a fresh minting account and (on test networks) fund it from the
 * faucet. Prints the bech32 secret key to paste into .env as SUI_SECRET_KEY.
 */
const keypair = new Ed25519Keypair();
const address = keypair.toSuiAddress();

console.log('address:      ', address);
console.log('SUI_SECRET_KEY=' + keypair.getSecretKey());

if (network === 'testnet' || network === 'devnet') {
  try {
    await requestSuiFromFaucetV2({ host: getFaucetHost(network), recipient: address });
    console.log(`\nRequested ${network} gas from faucet (may take a few seconds).`);
  } catch (e) {
    console.warn(`\nFaucet request failed (rate limited?): ${(e as Error).message}`);
    console.warn('Fund manually: https://faucet.sui.io/');
  }
}
