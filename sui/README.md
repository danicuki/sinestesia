# Sinestesia × Sui — mint the live painting

When a song ends, the finished artwork is stored on **Walrus** and minted on
**Sui** as a `Painting` NFT carrying provenance that it was created live: a
SHA-256 over the performance transcript, the Director model's prompts and the
timestamps.

```
final canvas ──▶ Walrus (store bytes) ──▶ blobId + url
performance  ──▶ sha256(transcript+prompts+timestamps) ──▶ provenance hash
                         │
                         ▼
                 sui move call painting::mint  ──▶ Painting NFT (+ event)
```

## Layout

- `move/sinestesia_nft/` — the on-chain package (`painting` module: `Painting`
  struct, `mint` entry fn, Display metadata, `PaintingMinted` event).
- `mint/` — TypeScript client: Walrus upload, provenance hashing, and the mint
  transaction (`@mysten/sui`).

## 1. Publish the Move package (once)

Needs the [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install)
on testnet with a funded address (`sui client faucet`).

```bash
cd sui/move/sinestesia_nft
sui move build
sui client publish --gas-budget 100000000
```

Copy the published **package id** into `sui/mint/.env` as `SUI_PACKAGE_ID`.

## 2. Set up the mint client

```bash
cd sui/mint
npm install
cp .env.example .env
npm run keygen          # prints SUI_SECRET_KEY and funds it from the faucet
# paste SUI_SECRET_KEY and SUI_PACKAGE_ID into .env
```

## 3. Mint

```bash
npm run mint -- --image path/to/final.png --performance sample-performance.json
```

Output:

```
→ storing final.png on Walrus…
  blobId  abc123…
  url     https://aggregator.walrus-testnet.walrus.space/v1/blobs/abc123…
→ provenance sha256 9f86d0…
→ minting on Sui…
✓ minted Painting
  object 0x…      view https://suiscan.xyz/testnet/object/0x…
```

## Verifying provenance later

Anyone can re-hash the stored transcript + prompts + timestamps and check it
equals the NFT's `provenance_hash`, and fetch the image from Walrus by
`walrus_blob_id` independently of any gateway. The NFT is proof of the exact
live moment that produced the painting.

## Wiring into the show (next)

`mintPainting()` and `storeBytes()` are plain functions — the live app calls
them at song end with the canvas `toBlob()` bytes and the performance record it
already has. A QR overlay pointing at `explorerUrl` lets the audience claim/view
the piece the instant the painting finishes.
