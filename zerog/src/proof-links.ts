/**
 * Resolve the publicly-checkable artefacts behind one Director turn.
 *
 *   npx tsx src/proof-links.ts <chatId> [providerAddress]
 *
 * There is no 0G explorer page keyed by chat id — the signature lives with the
 * provider, not on chain. What IS independently checkable is the pair this
 * prints: the chat's signature, and the TEE remote-attestation report that
 * binds the signing key to a sealed enclave running the claimed model. Recover
 * the signer from the signature and it must equal the attested signing address.
 */
import { getBroker, getService } from './broker.js';

const [, , chatId, providerArg] = process.argv;
if (!chatId) {
  console.error('usage: npx tsx src/proof-links.ts <chatId> [providerAddress]');
  process.exit(1);
}

const broker = await getBroker();
const provider = providerArg ?? (await getService()).provider;

const [sig, ra] = await Promise.all([
  broker.inference.getChatSignatureDownloadLink(provider, chatId).catch((e) => `ERROR: ${e.message}`),
  broker.inference.getSignerRaDownloadLink(provider).catch((e) => `ERROR: ${e.message}`),
]);

console.log(`provider        ${provider}`);
console.log(`chatId          ${chatId}`);
console.log(`chat signature  ${sig}`);
console.log(`signer RA       ${ra}`);
