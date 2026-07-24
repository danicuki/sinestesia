# Sinestesia @ ETHGlobal Lisbon 2026 — Battle Plan

**Event:** ETHGlobal Lisbon 2026 · Pavilhão Carlos Lopes · July 24–26, 2026
**Format:** 36h hackathon, 600+ hackers, $125k+ prizes. Existing repos allowed
if a **new feature is built during the event** (commit early and often — Git
history is judged; continuity tracks require a dated changelog).

## The feature we build

**Mint the live painting.** At the end of each song, the artwork Sinestesia
just painted live becomes a collectible with **provenance that it was created
live, from that performance** — a hash of the transcript + Director prompts +
timestamps, anchored onchain. One coherent feature: *the live AI painting
becomes an onchain keepsake anyone in the room can claim.*

Why it wins:
- It's a **real product feature** (the digital version of the "keepsake print"
  already in our monetization plan), not a hackathon toy.
- It **demos itself**: sing on stage → a painting grows → it mints → the room
  scans a QR to claim. No other team demos *emotion*; judges will have seen 100
  DeFi dashboards by Sunday.
- The venue is covered in **azulejos** and the schedule has an "Azulejo Tile
  Painting" social — perform one song in azulejo style and the room becomes the
  artwork.

## Prize targets (pick TWO, go deep — judges punish prize-farming)

1. **Sui — "Best existing app integrating Sui stack" ($2,000).** This track
   *requires a pre-existing product that adds Sui during the hackathon* — that
   is exactly us, and almost nobody else qualifies. Mint on Sui, store the
   artwork on **Walrus** (Sui's storage). Best eligibility fit in the building.
   *Booth judge: Alvaro Lillo (@TheContractHero).*
2. **0G — "Best AI Product" ($6k pool; $3k for 1st).** Route the Director LLM
   call through **0G Compute** (OpenAI-compatible API, TS SDK) for private,
   verifiable inference, and show the receipt on screen. We're already an AI
   product; this is a ~one-endpoint swap plus a sidecar. *≤3-min demo, needs
   deployment addresses.*

**Optional garnish (only if core is done by Saturday night):**
- **ENS "Most Creative Use" ($1,500)** — each performance minted under
  `<song>.sinestesia.eth`. Worth it *only because* ENS core dev **Makoto Inoue**
  is on the main finalist panel. Requires an in-person Sunday demo at the ENS
  booth.

Skip World, Hedera, Graph, 1inch, Uniswap — no honest fit; shallow integrations
lose.

## Why the finalist panel is cast for us

The real prize is being a **top finalist demoing live on the main stage** — a
bigger win than any single bounty, and this 24-person panel is unusually
favorable:

| Judge | Org | Why they matter for us |
|---|---|---|
| Nuno Loureiro | Ethereum Foundation | **Digital Studio / design lead** — our watercolor aesthetic is his language |
| Roberto Machado | Subvisual (ex-CPO Utrust) | Portuguese studio famous for **Elixir** — our backend is Elixir; instant rapport |
| Diogo Mónica | Haun Ventures (co-founder Anchorage) | Portuguese; biggest VC in the room; wants real shipped products |
| Pedro Gomes | WalletConnect | Portuguese; the "scan QR → claim painting" flow is a WalletConnect moment |
| João Alves | Bleap | Portuguese consumer-UX founder |
| Marcelo Kunze | Frames | Portuguese; "machine payments" / design engineer |
| Simona Pop | Human Protocol | Narrative/community — the human×AI-art story lands |
| Solange Gueiros | Chainlink DevRel | Brazilian educator — a PT-language demo is a bonus |
| Makoto Inoue | ENS | On the panel → makes the ENS garnish strategically worth it |

**Mentor to find Friday night:** **Tahi Gichigi** (mooch.agency, works with the
Ethereum Foundation) — self-described *"big AI art NFT collector."* Our project
is his entire profile. First conversation of the weekend.

Read on the room: ~5 Portuguese builders + an EF design lead + an Elixir-studio
founder + an AI-art-collector mentor. Lean into Lisbon soul and live emotion.

## Two judging moments (Sunday)

- **Partner Prize Judging** — sponsor DevRel teams judge their own bounties at
  booths (Sui, 0G, ENS for us). Bring the ≤3-min demo video + deployment
  addresses + public repo.
- **Main Finalist Judging** — the 24-person panel on the main stage. Play for
  this with the live performance.

## 36-hour plan

**Friday (kickoff + setup)**
- Talk to Tahi Gichigi (mentor) and the Sui + 0G booths early; confirm eligibility
  reading of the Sui existing-app track with Alvaro directly.
- Scaffold: `mint/` module (Sui + Walrus, TS) and `inference/` 0G sidecar.
- First commit tonight (starts the dated changelog).

**Saturday (core build)**
- Walrus upload of the final canvas + Sui mint at song-end. Provenance payload =
  hash(transcript + Director prompts + timestamps).
- Swap Director inference to the 0G endpoint; render the verifiable-inference
  receipt on screen.
- On-screen mint moment: painting finishes → "minted ✓" → QR to claim.
- Azulejo style preset for the demo song.

**Sunday (polish + demo)**
- Record the ≤3-min demo video (needed for both booths). Collect deployment
  addresses. Write the "what we built at Lisbon" changelog.
- Live performance for the finalist panel if selected.

## Ground rules (from the event FAQ)

- AI tools (Claude Code, Copilot, etc.) are **explicitly allowed**.
- Public GitHub repo required; **commit throughout** — Git history is judged
  (1inch even scores it explicitly; continuity tracks require a dated changelog).
- Keep demos within each sponsor's time limit (0G ≤3 min).

---
*Companion to `MONETIZATION.md` — the mint feature is the onchain version of the
keepsake product line.*
