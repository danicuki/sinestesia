# Sinestesia × 0G — verifiable AI direction

Sinestesia's **Director** is the AI that turns each sung line into the next
visual prompt — it *is* the intelligence of the show. This sidecar routes that
Director through the **0G Compute Network**, so every prompt is produced by a
**TEE-sealed model** whose output is cryptographically attestable. The show then
displays, live, a **"Verifiable AI" badge** proving the visuals were directed by
a real model in a sealed enclave — not a stand-in.

```
sung line ─▶ Director (Elixir) ─▶ POST /v1/chat/completions ─▶ 0G sidecar (this)
                                                                   │
                        broker.getRequestHeaders (on-chain signed) │
                                 fetch → TEE provider (TeeML)       │
                        broker.processResponse  (verify signature)  ▼
                    ◀── prompt + { verified, model, provider, chatId } ──
                                        │
                        image message ──┼──▶ on-screen "Verifiable AI" badge
```

The Director keeps its provider **fallback chain**: if 0G is slow or down, it
silently falls back to local Gemma so the visuals never stall — and the badge
reflects which one actually ran.

## Why it's decoupled

The 0G SDK is TypeScript-only and signs every request against an on-chain
ledger, so it can't live inside the Elixir backend. Instead this sidecar exposes
a plain **OpenAI-compatible** endpoint (`POST /v1/chat/completions`). The Elixir
Director just does an HTTP POST (provider `:zerog`) — no crypto in Elixir, and
any OpenAI-speaking service could be swapped in behind the same interface.

## Layout

- `src/broker.ts` — the 0G broker wrapper: init, acknowledge provider, signed
  request headers, TEE verification (`verifiedChat`). This is where "verifiable"
  actually happens.
- `src/server.ts` — the OpenAI-compatible HTTP sidecar the Director calls.
- `src/setup.ts` — one-time account/ledger funding + provider acknowledge.
- `src/providers.ts` — list the live verifiable providers on the network.
- `src/config.ts` — env config.

Backend integration (already wired in this branch):
- `backend/lib/sinestesia/director.ex` — `:zerog` provider + fallback chain.
- `backend/lib/sinestesia/verifiability.ex` — holds the latest receipt.
- `backend/lib/sinestesia/pipeline.ex` — attaches the receipt to `image` messages.
- `frontend/src/verify_badge.ts` — the on-screen badge.

---

## Operator runbook

### 0. Prerequisites (once per machine)

- Node ≥ 20 (`node -v`).
- A wallet private key with **0G testnet** tokens. Create one with any EVM
  wallet, then get testnet 0G from the faucet: https://faucet.0g.ai/
  (ETHGlobal Lisbon promo code for extra tokens: **`ETH-LISBON-26`**).
  Explorers: chain https://chainscan-galileo.0g.ai/ · storage
  https://storagescan-galileo.0g.ai/

### 1. Install + configure

```bash
cd zerog
npm install
cp .env.example .env
```

Put your funded wallet key in `.env`:
- `ZG_PRIVATE_KEY` = `0x…` (the wallet that pays for inference)

### 2. Pick a live verifiable provider

Provider addresses change; confirm what's live and pick a **TeeML** (verifiable)
**chat** model:

```bash
npm run providers
```
Set `ZG_PROVIDER` in `.env` to a chat provider's address (e.g. the
`qwen2.5-omni-7b` provider). The image-edit provider is not for the Director.

### 3. Fund the ledger + acknowledge the provider (once)

```bash
npm run setup
```
This prints your wallet address and balance, creates/funds the on-chain ledger
(amount = `ZG_DEPOSIT`, default 0.1 0G), acknowledges the provider's TEE signer,
and confirms the model/endpoint. Re-run any time to top up.

### 4. Start the sidecar

```bash
npm run serve
# [0g] sidecar on http://127.0.0.1:8788
# [0g] ready — model qwen/qwen2.5-omni-7b @ https://…
```

Quick check:
```bash
curl -s localhost:8788/healthz            # { ok, endpoint, model, provider }
```

### 5. Point the Director at 0G

In the backend's environment:
```bash
export DIRECTOR_PROVIDER=zerog
# optional if the sidecar isn't on the default port/host:
export ZEROG_SIDECAR_URL=http://127.0.0.1:8788
```
Start the backend as usual. Sing a line → the Director prompt is now computed on
0G, and the projection shows the **Verifiable AI** badge (green = TEE-verified).
Add `?no-verify` to the frontend URL to hide the badge.

## Verifying the claim

Each `image` message carries a `verification` receipt:
```json
{ "provider": "0xa48f…", "model": "qwen/qwen2.5-omni-7b",
  "chatId": "chatcmpl-…", "verified": true, "network": "0g-compute" }
```
`verified: true` means the sidecar checked the provider's **TEE (TeeML)
signature** for that exact response via `broker.inference.processResponse` — the
prompt provably came from that sealed model, and the micro-payment settled
on-chain. `chatId` ties the receipt to the specific inference.

## Status

Verified here: sidecar **typechecks**; server **boots and routes** against the
live 0G testnet (chain ID 16602); `npm run providers` **lists live TeeML
providers**; backend **compiles** with the `:zerog` provider; frontend
**builds** with the badge. Real paid inference is pending a **funded** testnet
wallet (faucet-gated in CI; runs normally on a workstation) — exactly like the
Sui mint. `npm run setup` then `npm run serve` completes it.
