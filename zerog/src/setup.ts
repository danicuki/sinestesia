import { ethers } from 'ethers';
import { getBroker, getService } from './broker.js';
import { depositAmount, privateKey, providerAddress, rpcUrl } from './config.js';

/**
 * One-time (per machine) account setup: create/fund the 0G ledger and
 * acknowledge the provider so `npm run serve` can make paid inference calls.
 *
 *   npm run setup
 *
 * Prints the wallet address, on-chain balance, ledger balance, and the
 * provider's endpoint/model so you can confirm everything before the show.
 */
async function main() {
  const provider = new ethers.JsonRpcProvider(rpcUrl());
  const wallet = new ethers.Wallet(privateKey(), provider);
  const bal = await provider.getBalance(wallet.address);
  console.log(`wallet   ${wallet.address}`);
  console.log(`balance  ${ethers.formatEther(bal)} 0G (testnet)`);
  if (bal === 0n) {
    console.log('⚠ zero balance — get testnet 0G from the faucet first, then re-run.');
  }

  const broker = await getBroker();

  // Ensure a ledger exists and holds funds. addLedger creates + deposits;
  // if it already exists, top it up with depositFund instead.
  const amount = depositAmount();
  try {
    await broker.ledger.addLedger(amount);
    console.log(`ledger   created + funded with ${amount} 0G`);
  } catch {
    try {
      await broker.ledger.depositFund(amount);
      console.log(`ledger   topped up with ${amount} 0G`);
    } catch (err) {
      console.log(`ledger   already funded (${(err as Error).message})`);
    }
  }

  try {
    const ledger = await broker.ledger.getLedger();
    console.log(`ledger   balance ${JSON.stringify(ledger)}`);
  } catch {
    /* getLedger shape varies by SDK version — non-fatal */
  }

  await broker.inference.acknowledgeProviderSigner(providerAddress());
  console.log(`provider ${providerAddress()} acknowledged`);

  const svc = await getService();
  console.log(`service  model ${svc.model} @ ${svc.endpoint}`);
  console.log('✓ setup complete — run `npm run serve`.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
