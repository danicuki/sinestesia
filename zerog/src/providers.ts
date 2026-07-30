import { getBroker } from './broker.js';

/**
 * List the inference services currently live on the 0G Compute Network, so you
 * can pick a valid `ZG_PROVIDER` for `.env`. Provider addresses are dynamic —
 * the one baked into `.env.example` can go offline — so run this before a show:
 *
 *   npm run providers
 *
 * Prints each provider's address, model, verifiability type (TEE/TeeML means the
 * response is cryptographically attestable — that's the one you want), and price.
 */
async function main() {
  const broker = await getBroker();
  const services = await broker.inference.listService();

  if (!services || services.length === 0) {
    console.log('No services listed. Check RPC connectivity and try again.');
    return;
  }

  console.log(`Found ${services.length} service(s):\n`);
  for (const s of services as unknown as Record<string, unknown>[]) {
    const addr = s.provider ?? s.providerAddress ?? s.address ?? '(unknown)';
    const model = s.model ?? '(default)';
    const verify = s.verifiability ?? s.verifiabilityType ?? s.serviceType ?? '';
    const price = s.inputPrice ?? s.pricePerToken ?? s.price ?? '';
    console.log(`  ${addr}`);
    console.log(`    model        ${model}`);
    if (verify) console.log(`    verifiability ${verify}`);
    if (price !== '') console.log(`    price        ${price}`);
    console.log('');
  }
  console.log('Set ZG_PROVIDER in .env to a TEE/TeeML provider address above.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
