# Sinestesia × Sui — mint the live painting

When a song ends, the finished artwork is stored on **Walrus** and released on
**Sui**: a **master 1/1** goes to the artist, and anyone in the room can claim a
free **open-edition print** (they pay only gas). Every token carries provenance
that it was created live — a SHA-256 over the performance transcript, the
Director model's prompts and the timestamps.

```
final canvas ─▶ Walrus (store bytes) ─▶ blobId + url
performance  ─▶ sha256(transcript+prompts+timestamps) ─▶ provenance hash
             ─▶ deriveTraits() ─▶ palette / motifs / strokes / rarity
                         │
                         ▼
        painting::create_release ─▶ master 1/1 → artist  +  shared Release
                         │
        painting::claim_print(Release) ─▶ print #1..N → each audience wallet
```

## Layout

Chain-agnostic by design — storage and blockchain are pluggable interfaces. One
performance is stored once and can be released to any number of chains.

- `move/sinestesia_nft/` — on-chain package (`painting` module): `Release`
  (shared, holds metadata + print counter), `Painting` NFT (master or print),
  `create_release` / `claim_print` / `set_open`, Display, and events.
- `mint/src/storage/` — `Storage` interface + `WalrusStorage` (swap in IPFS/Arweave).
- `mint/src/chains/` — `Minter` interface + `SuiMinter` (add EVM/Solana by
  implementing `Minter`; nothing else changes).
- `mint/src/traits.ts` — rarity derived from the performance itself.
- `mint/src/paint-and-mint.ts` — pipeline: store once → hash → traits → release
  on every configured chain.

## Minting rules (current)

| Rule | Value |
|---|---|
| Per song | 1 master (1/1, edition 0) + open-edition prints (1..N) |
| Master goes to | the artist (tx sender of `create_release`) |
| Print price | **free** — claimer pays only gas |
| Who can claim | anyone, while the window is `open` |
| Close the window | artist calls `set_open(release, false)` |
| Rarity | derived from the performance (palette, motifs, strokes, duration) |

---

## Operator runbook

### 0. Install the Sui CLI (once per machine)

**macOS** (recommended):
```bash
brew install sui
```

**Linux** (prebuilt binary):
```bash
VER=testnet-v1.76.0
curl -L -o sui.tgz \
  "https://github.com/MystenLabs/sui/releases/download/$VER/sui-$VER-ubuntu-x86_64.tgz"
tar xzf sui.tgz && install -m755 sui ~/.local/bin/sui   # ensure ~/.local/bin is on PATH
```

Verify: `sui --version`.

### 1. Point the CLI at testnet + create an address (once)

```bash
sui client   # first run: answer y, URL https://fullnode.testnet.sui.io:443, alias testnet, key scheme 0
sui client active-address
```

### 2. Fund the address

```bash
sui client faucet        # or open the URL it prints (https://faucet.sui.io/)
sui client gas           # confirm you have coins
```
> The public faucet is rate-limited per IP. If the CLI faucet is throttled, use
> the web UI at https://faucet.sui.io/ with your address.

### 3. Publish the Move package (once)

```bash
cd sui/move/sinestesia_nft
sui move build
sui client publish --gas-budget 100000000
```
From the output, copy the **package id** (the `Published Objects` → `PackageID`).

### 4. Configure the mint client

```bash
cd sui/mint
npm install
cp .env.example .env
```
Put two things in `.env`:
- `SUI_PACKAGE_ID` = the package id from step 3.
- `SUI_SECRET_KEY` = the artist account's key. Export the CLI's active key with
  `sui keytool export --key-identity $(sui client active-address)` (the
  `suiprivkey1…` value), **or** run `npm run keygen` to make a fresh funded one.

### 5. Release a song (artist) — mints the master 1/1 + opens prints

```bash
npm run mint -- release --image path/to/final.png --performance sample-performance.json
```
Output:
```
  image   https://aggregator.walrus-testnet.walrus.space/v1/blobs/…
  blobId  …
  proof   sha256 …
  traits  {"dominantColor":"yellow","rarity":"legendary",…}
✓ sui: master 1/1 0x…            ← the artist keeps this
    release 0x…                  ← audience claims prints against THIS id
    view    https://suiscan.xyz/testnet/object/0x…
```
Save the **release** id — that's what the QR code / audience uses.

### 6. Claim a print (audience) — free, pays only gas

```bash
npm run mint -- claim --release 0xRELEASE_ID
```
In the live show this call is made from each audience member's own wallet
(scan QR → approve). The CLI form above signs with the configured key for
testing.

### 7. Close the window when the song's moment is over (optional)

```bash
sui client call --package $SUI_PACKAGE_ID --module painting \
  --function set_open --args 0xRELEASE_ID false --gas-budget 10000000
```

### Multiple chains

`--chains sui,evm` on `release` mints the same painting on every listed chain
once each `Minter` exists. Only `sui` is implemented today.

## Verifying provenance later

Anyone can re-hash the stored transcript + prompts + timestamps and check it
equals the token's `provenance_hash`, and fetch the image from Walrus by
`walrus_blob_id` independently of any gateway. The NFT is proof of the exact
live moment that produced the painting.

## Wiring into the live show (done)

The mint is wired end-to-end. Instead of the CLI, run the **mint sidecar** and
the backend triggers it at song end:

```bash
# 1. mint sidecar (needs a published package + funded key in sui/mint/.env)
cd sui/mint && npm run serve      # http://127.0.0.1:8790

# 2. backend points at it; set the show metadata + a phone-reachable claim URL
export MINT_SIDECAR_URL=http://127.0.0.1:8790
export MINT_ARTIST="…"  MINT_VENUE="…"           # song is sent per-mint from the UI
export CLAIM_PUBLIC_URL=http://<LAN-or-tunnel>:8790   # so audience phones can reach the QR target
export MINT_COMPOSE=webp   # NFT image = whole song: webp (default) | gif | collage | final
export MINT_FRAME_MS=600   # per-frame delay (pacing). Higher = slower playback.
# Point the on-chain image_url at the sidecar's content-type-serving proxy so it
# renders in every wallet (Walrus serves blobs untyped). Set to the SAME public
# host as CLAIM_PUBLIC_URL; if unset, image_url falls back to the raw Walrus URL.
export MINT_IMAGE_BASE=http://<LAN-or-tunnel>:8790
```

Flow: when the song ends the operator hits **Finish & Mint** (button, or the
`m` key in clean/stage mode). The backend assembles the performance record it
accumulated during the song (transcript + every Director prompt + timestamps)
plus **every generated frame URL**, and POSTs to the sidecar's `POST /release`.
The sidecar composes the frames into the NFT image — an **animated WebP of the
whole song's evolution** by default (`MINT_COMPOSE=gif` for max compatibility,
`collage` for a contact sheet, `final` for just the last frame) — stores it on
Walrus, and mints the master 1/1 on Sui. Every Director beat is included (a
4-min song is ~40–60 beats; the interpolation frames never reach the mint), so
the NFT is the whole song, not a sample. WebP keeps that to a small, full-colour
file (~0.5MB for 41 beats vs ~2MB as GIF).

**Rendering in wallets:** Walrus serves blobs with no content-type (+ nosniff),
which some marketplaces require. With `MINT_IMAGE_BASE` set, the on-chain
`image_url` points at the sidecar's `/img/<blob>.<ext>` proxy, which streams the
blob with the correct MIME + extension; the canonical `walrus_blob_id` is stored
on-chain regardless, so the blob stays independently retrievable. The returned `claimUrl` is
pushed to the frontend, which renders a **QR overlay** (`mint_overlay.ts`);
scanning it opens the sidecar's `/claim` page and mints a free print. See
`PROTOCOL.md` (`mint` messages) for the wire format.

> For the demo the show wallet pays the print gas. A production build would
> connect each visitor's own wallet — the `POST /claim` contract already accepts
> a `to` address for that.

## Status

Verified: Move package **builds** (Sui 1.76); mint client + **sidecar
typecheck**; sidecar **routes** (health / release-validation / claim page) smoke-
tested; Walrus store + read-back **live on testnet**; provenance + traits
**tested**; backend **compiles** and frontend **builds** with the trigger + QR
overlay. The on-chain publish/mint is pending a funded testnet address (blocked
only by faucet rate-limits in CI; runs normally on a workstation).

## Status

Verified: Move package **builds** (Sui 1.76); TS **typechecks**; Walrus store +
read-back **live on testnet**; provenance + traits **tested**. The on-chain
publish/mint is pending a funded testnet address (blocked only by faucet
rate-limits in CI; runs normally on a workstation).
