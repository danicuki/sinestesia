# ETHGlobal Lisbon 2026 — submission plan

Read against the official Project Rules deck. Status as of **Sat 25 Jul**, with
submission Sunday morning — roughly **24 hours**. Ordered by what actually
blocks eligibility, not by what's most fun.

## Track: 02 — Extend Open Source

`danicuki/sinestesia` is a public repo created **2026-06-04**, before the event,
and we shipped a new feature during it. That is exactly Track 02.

- You can only pick **one** track, it applies to the whole team, and selection
  happens **on your ETHGlobal dashboard**. Do this early — it gates prizes.
- The deck says: *"Fork the existing repo to show changes — we prefer this over
  branches."* We used a branch (`feat/hackathon`). See the fork decision below.

## Blocking gaps (P0 — finalist eligibility)

Finalist requires: auditable repo · **open source** · **deployed and live** ·
demo video · live judging (4 min demo + 3 min Q&A).

| # | Gap | Why it blocks | Fix |
|---|-----|---------------|-----|
| 1 | **No LICENSE file** | "Open source" is a hard requirement. No license = all rights reserved by default, i.e. *not* open source | Add one (decision needed — see below) |
| 2 | **Not deployed / live** | Explicit finalist requirement | Deploy plan below |
| 3 | **Track not selected** | Prizes are track-specific | Select Track 02 on the dashboard |
| 4 | **No demo video** | Required at submission | Script in `VIDEO_SCRIPTS.md` |
| 5 | **Branch, not fork** | Deck states a preference, not a rule | See below |

### 1. License — needs your call

The repo has **no license**, and you have commercial plans,
so this is not a rubber-stamp:

- **MIT / Apache-2.0** — maximum goodwill, judges and sponsors love it. Anyone
  (including a festival-software company) can take it closed-source.
- **AGPL-3.0** — still unambiguously open source and hackathon-compliant, but a
  company running it as a service must publish their changes. Protects the
  commercial path; some partners are wary of it.

Apache-2.0 also grants patent rights explicitly, which is the friendlier
"serious project" signal. Pick one and it goes in before submission.

### 5. Fork vs branch

The deck *prefers* a fork so the diff is auditable. Our branch already gives a
clean diff (`main...feat/hackathon`, ~20 well-scoped commits), which satisfies
the intent. Two options:

- **Cheapest:** keep the branch, and put the compare link
  (`/compare/main...feat/hackathon`) at the top of the project page and README
  so judges land directly on the diff.
- **Closest to the letter:** push the branch to a second public repo
  (e.g. `sinestesia-lisbon`) whose default branch is the hackathon work.

The deck also says *"talk to us about edge-cases"* — this is a 30-second question
for the ETHGlobal team on site, and worth asking rather than guessing.

## Deployment plan (P0 #2)

The show runs **locally** for the live performance (lowest latency, local models
available). The **deployment** exists so judges can reach it and because it is
required. Both must exist; don't conflate them.

### What can and cannot go to the cloud

| Component | Cloud? | Notes |
|---|---|---|
| Frontend (Vite static) | ✅ Vercel | set `VITE_WS_URL` to the backend |
| Backend (Elixir/Bandit, WebSocket) | ✅ Fly.io | needs a Dockerfile — biggest lift |
| Mint sidecar (`sui/mint`) | ✅ Vercel | **already done**, `api/index.ts` |
| 0G sidecar (`zerog`) | ✅ Fly.io / Vercel | Node, no native deps |
| STT (ElevenLabs / Deepgram) | ✅ | cloud APIs, just keys |
| Image gen (fal.ai / Cloudflare) | ✅ | cloud APIs, just keys |
| Director on 0G Compute | ✅ | that's the point |
| **Ollama / Gemma** | ❌ | local model, no GPU in the cloud |
| **local SDXL, local Whisper** | ❌ | same |

The local-only pieces are **fallbacks**, so losing them in the cloud is fine —
but note the Director chain is `0G → gemma → gemini → haiku`. In the cloud the
gemma hop always fails, so **set `GOOGLE_API_KEY` or `ANTHROPIC_API_KEY`** or a
0G hiccup means no visuals at all.

### Order of work

1. **Frontend + mint sidecar to Vercel** (~30 min, low risk) — the mint app is
   already deployable; the frontend is a static build.
2. **Backend to Fly.io** (~2h, the real work) — write a Dockerfile (Elixir
   release), `fly launch`, set secrets, confirm the WebSocket upgrade works
   through Fly's proxy.
3. **0G sidecar** alongside it, then point `ZEROG_SIDECAR_URL` at it.
4. **Wire the hostnames** — `VITE_WS_URL=wss://…`, `MINT_SIDECAR_URL`,
   `CLAIM_PUBLIC_URL`, `MINT_IMAGE_BASE` all pointing at public hosts.

Two things that will bite:

- **`getUserMedia` requires HTTPS.** Deployed HTTPS is actually *better* than
  localhost for phones — but any mixed-content (`ws://` from an `https://` page)
  will silently fail. Use `wss://`.
- **Audio over the internet adds latency** to every STT round trip. Expect the
  deployed app to feel slower than the local show. That is fine and worth saying
  out loud in the video rather than hoping nobody notices.

### Domains

`www.sinestesia.*` → landing, `app.sinestesia.*` → the app. Requires buying a
domain and pointing DNS at Vercel/Fly. If time runs out, the `*.vercel.app` and
`*.fly.dev` URLs satisfy "deployed and live" perfectly well — **do not let the
domain block the deploy.**

## Partner prizes

Up to **3** partners at submission. We have two with real integrations:

- **Sui** — Move contract, master 1/1 + open-edition prints, Walrus storage,
  on-chain provenance whose preimage is published and re-verifiable.
- **0G** — Director inference on TEE-sealed verifiable compute, receipts
  surfaced live on the projection.

A third only if the integration is real. A thin one reads worse than two strong.

## "How did you use AI?" (they will ask)

The deck says you'll be asked, and recommends committing plan files. We already
have `HACKATHON.md`, `DEMO_RUNBOOK.md`, this file, `VIDEO_SCRIPTS.md` and
`DESIGN_BRIEF.md` in-repo. Be ready to say plainly: agent-assisted development
throughout, with every integration verified against live networks (real Walrus
blobs, real Sui testnet mints, real 0G provider listings) rather than trusted
from memory. The commit history shows small, reviewed diffs — which is exactly
what the deck asks for.

Also worth having ready: the honest bugs we found and fixed by testing rather
than assuming — the frame-cropping bug, the 4.4 MB GIF, the stale 0G provider in
the docs, the local model confidently misnaming a song. That is a *better* answer
than "the AI wrote it and it worked".

## Definition of done

- [ ] LICENSE committed
- [ ] Track 02 selected on the dashboard
- [ ] Backend live (Fly), frontend live (Vercel), mint app live (Vercel)
- [ ] One end-to-end run **on the deployed stack**: sing → paint → mint → claim
- [ ] Demo video recorded and linked
- [ ] Project page: description, screenshots, the `main...feat/hackathon` diff link
- [ ] Sui + 0G selected as partners
