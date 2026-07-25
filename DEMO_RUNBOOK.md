# Live demo dry-run — real on-chain mint + verified 0G receipt

Run this on the Mac **before** the demo. Branch: `feat/hackathon` (has both the
Sui mint and the 0G verifiable-inference feature). Do the two chains in any
order; both are faucet-gated, so fund early.

Ports: **8788** = 0G sidecar · **8790** = mint sidecar · backend/front as usual.

---

## 0. Prereqs
- [ ] `node -v` ≥ 20
- [ ] `brew install sui` → `sui --version`
- [ ] An EVM wallet private key (for 0G) and a Sui key (created below)
- [ ] Existing Sinestesia env in place (STT + image-gen API keys)

---

## A. Sui + Walrus (mint)

1. [ ] **Testnet client + funds**
   ```bash
   sui client            # first run: y, https://fullnode.testnet.sui.io:443, alias testnet, key scheme 0
   sui client faucet     # or https://faucet.sui.io/ with your address
   sui client gas        # confirm coins
   ```
2. [ ] **Publish the Move package** (once) — copy the PackageID from output
   ```bash
   cd sui/move/sinestesia_nft
   sui move build
   sui client publish --gas-budget 100000000
   ```
3. [ ] **Configure the mint client**
   ```bash
   cd ../../mint          # sui/mint
   npm install
   cp .env.example .env
   ```
   In `.env`: `SUI_PACKAGE_ID=<from step 2>`,
   `SUI_SECRET_KEY=$(sui keytool export --key-identity $(sui client active-address) --json | jq -r .exportedPrivateKey)`
   (the `suiprivkey1…` value). `.env` auto-loads — no manual `source` needed.
   - If a mint later fails with **`Unexpected status code: 404`**, the default
     public RPC is unreachable from your network; add a working one to `.env`:
     `SUI_FULLNODE_URL=https://rpc-testnet.suiscan.xyz` (verified working).
4. [ ] **Start the mint sidecar** — set `CLAIM_PUBLIC_URL` to a **phone-reachable**
   address (LAN IP or an ngrok tunnel), or the QR won't work from the room:
   ```bash
   CLAIM_PUBLIC_URL=http://<your-LAN-IP>:8790 npm run serve
   ```
   - [ ] `curl localhost:8790/healthz` → `{"ok":true}`
5. [ ] **Smoke a real mint** (proves package + Walrus + Sui all work end-to-end)
   ```bash
   npm run mint -- release --image path/to/any.png --performance sample-performance.json
   ```
   - [ ] Output shows a Walrus `blobId`, a `master 1/1 0x…`, and a `release 0x…`
   - [ ] Open the `view` URL — the object exists on Suiscan
   - [ ] Claim once: `npm run mint -- claim --release 0x<RELEASE>` → print #1

---

## B. 0G Compute (verifiable Director)

1. [ ] **Configure**
   ```bash
   cd zerog
   npm install
   cp .env.example .env      # put ZG_PRIVATE_KEY=0x… (your EVM key)
   ```
2. [ ] **Fund the wallet** — https://faucet.0g.ai/ , promo code **`ETH-LISBON-26`**
   (verify on https://chainscan-galileo.0g.ai/)
3. [ ] **Pick a live provider** (addresses are dynamic)
   ```bash
   npm run providers        # copy a TeeML *chat* provider address into ZG_PROVIDER
   ```
4. [ ] **Fund ledger + acknowledge**, then start the sidecar
   ```bash
   npm run setup            # creates/funds ledger, acknowledges provider, prints model
   npm run serve            # http://127.0.0.1:8788
   ```
   - [ ] `curl localhost:8788/healthz` → `{ ok:true, model, endpoint, provider }`

---

## C. Backend + frontend (tie it together)

1. [ ] **Export the wiring** (in the backend shell, alongside your usual keys)
   ```bash
   export DIRECTOR_PROVIDER=zerog                 # route the Director through 0G
   export ZEROG_SIDECAR_URL=http://127.0.0.1:8788
   export MINT_SIDECAR_URL=http://127.0.0.1:8790
   export MINT_ARTIST="Your Name"  MINT_VENUE="ETHGlobal Lisbon"
   ```
2. [ ] **Start backend** (`mix run --no-halt` / your usual) and **frontend** (`npm run dev`)
3. [ ] **Verify the Director is on 0G**: sing/replay a line →
   - [ ] the **green "Verifiable AI" badge** appears (bottom-left) with the model name
   - [ ] backend log shows a `[director]` turn (no fallback warning)
4. [ ] **Verify the mint**: at song's end press **End Song** (or the **`m`** key) →
   - [ ] the canvas clears immediately — the next song can start right away
   - [ ] "Minting…" appears in the **bottom-right corner**, then the **QR** with
         the song title (the show is never covered by a modal)
   - [ ] scan the QR from a phone on the same network → claim page → "You own print #N"
   - [ ] the "view on-chain" link opens the object on Suiscan

---

## Pre-show gotchas
- **QR must be reachable from phones.** `CLAIM_PUBLIC_URL` = LAN IP or ngrok, not
  `localhost`. Test from an actual phone, not the laptop.
- **Fund all three** before you go on: Sui gas, 0G wallet, 0G ledger (`npm run setup`).
- **0G latency**: it's a 70B-class model over the network (~seconds). If it drags,
  the Director falls back to local Gemma automatically — the badge will show that.
  Keep the local model warm as insurance.
- **Gas for prints**: the show wallet pays. Make sure the Sui key in `sui/mint/.env`
  has enough gas for as many claims as you expect from the room.
- **One button ends a song.** "End Song" (or **`m`**) mints *and* resets, in that
  order, backend-side. To start over **without** minting — soundcheck, false
  start — press **`r`**. That one discards the performance, so it's keyboard-only.
