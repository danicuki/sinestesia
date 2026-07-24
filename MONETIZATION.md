# Sinestesia — Monetization Strategy

How to turn Sinestesia into income, ordered by **time-to-first-euro** and grounded in
what already exists in this repo. Written 2026-07-13.

## What we're selling (three distinct products hiding in one repo)

Sinestesia is not one product. The codebase already contains three sellable things:

1. **The live act** — Daniella + Dani + the system on stage. Proven at NFC Summit,
   with a YouTube demo and a complete `TECHNICAL_RIDER.md`. Ready to book *today*.
2. **The video factory** — the headless replay pipeline (`mix sinestesia.replay`)
   that turns any recorded song into a synchronized, hand-drawn MP4 music video.
   This is an offline service business with no live-performance risk.
3. **The engine** — the software itself, licensable to other performers, VJs,
   venues, and event producers.

The unit economics are already excellent: with the local SDXL sidecar the marginal
cost per song is near zero (ElevenLabs STT is the only recurring cloud cost, and
`IDEAS.md` has a path to killing even the fal.ai first-frame). Almost everything
below is margin.

---

## Phase 1 — Money now (0–2 months, no new code)

### 1.1 Book the live act (highest €/hour, zero engineering)

The show is the product. Nobody else in the corporate/event market has "an AI that
paints your event's soundtrack live on the wall."

| Market | Why they pay | Realistic fee (EU) |
|---|---|---|
| Corporate events / product launches / galas | "Innovative AI experience" is exactly what event planners are asked to find right now | €2,000–6,000 / show |
| Weddings ("your first dance, painted live") | High emotional value + they keep the artwork | €1,000–2,500 / event |
| Tech conferences (AI/dev events especially) | The show *is* a live tech demo — often paid from the speaker/entertainment budget | €1,500–4,000 + travel |
| Festivals / cultural programming | Novel AV act, rider already written | €800–3,000 |

**Actions:**
- Cut the NFC Summit footage into a 60–90s vertical showreel; that clip is the sales asset.
- One landing page: video, one paragraph, the rider, a booking form.
- Pitch directly to event agencies in Lisbon/Porto (they resell you; give them 15–20%).
- The wedding angle deserves its own pitch page — planners search for "unique first dance ideas."

### 1.2 The souvenir upsell (uses the replay pipeline as-is)

Every live booking can carry a **per-event artifact upsell**, because the session
JSON is already recorded and `mix sinestesia.replay` already produces the deliverables:

- **The final canvas as a fine-art print** (the "painting of your song"): €80–200.
- **The full synchronized MP4** of the performance: €150–400.
- Wedding package: print + video bundled into the booking fee (+€300–500).

Marginal cost: a print-on-demand order and a few minutes of GPU. This can add
20–30% to every show's revenue.

### 1.3 Grants and cultural funding (this project is grant-shaped)

A live AV performance mixing Brazilian MPB heritage with sovereign, on-device AI is
precisely what cultural funders want to fund:

- **Portugal**: GDA Foundation, Câmara Municipal de Lisboa cultural grants, Antena 2 / arts programming.
- **EU**: Creative Europe (culture strand), S+T+ARTS residencies (art+tech — perfect fit).
- **Brazil connection**: Ibermúsicas mobility grants; Lei Rouanet / ProAC via a Brazilian producer partner for a Brazil tour.
- **Festivals with paid AV programs**: Sónar+D, MUTEK, Ars Electronica, LEV Festival — application-based, they pay fees + travel.

One accepted application typically covers €3k–25k. The demo video and rider mean
applications are mostly writing work.

### 1.4 Paid talks & sponsored demos

The stack (local Gemma via Ollama, Elixir/OTP orchestration, fal.ai, ElevenLabs) is
a showcase every vendor in it wants:

- Conference talks ("How we built a live AI VJ on the BEAM") — ElixirConf EU, AI meetups; paid or leads to bookings.
- Pitch fal.ai / ElevenLabs / Ollama for **sponsored appearances or case-study fees** — their marketing teams pay for exactly this kind of flagship demo.

---

## Phase 2 — Productize the video factory (2–4 months, small engineering lift)

**"Send us a song, get back a hand-drawn animated music video."**

The replay pipeline is ~80% of a service business already. Independent musicians pay
€300–2,000 for lyric videos today; Sinestesia produces something more distinctive for
near-zero marginal cost.

- **Service tier (start here, manual):** musician sends a track → run it through the
  pipeline → curate the best run → deliver MP4. Price €200–500/video. Sell via
  Instagram/TikTok examples and direct outreach to indie artists. Each delivered
  video is also marketing (watermark + credit).
- **Self-serve tier (later):** upload → pay → rendered video. Needs upload UI,
  queueing, payments (Stripe), and STT-on-file instead of live mic. Price
  €30–80/video self-serve, volume business.

Engineering gaps to close for self-serve: batch STT on uploaded audio, job queue,
payment + delivery flow, style presets. The Elixir backend is well-suited to the
queueing part.

## Phase 3 — License the engine (4–12 months, only if pull appears)

Don't build this speculatively — start it when Phase 1/2 customers ask "can *we*
use it?"

- **Performer license:** other singer-songwriters/VJs run Sinestesia in their own
  shows. €50–100/month or €500–1,000/year + setup support. Requires packaging
  (installer, onboarding, key management) — real work, so gate it on demand.
- **Venue license:** karaoke venues, piano bars, churches/worship (a large,
  established market for live lyric visuals — ProPresenter's world), yoga/sound-
  healing studios. Per-venue subscription €100–300/month.
- **Event-producer license:** agencies that want the effect without the duo.
  Higher price, includes training: €2–5k/year.

A cloud-hosted version is possible (the per-song cost is known and low) but local-
first is also a *selling point* — venues with bad Wi-Fi, privacy, no per-use fees.

---

## What NOT to do (for now)

- **Don't build a consumer app** ("sing at home and watch drawings") — fun, viral
  potential, but monetizes poorly and drags the roadmap toward mobile/support hell.
- **Don't start with SaaS.** Selling software to musicians is famously hard;
  selling *performances* and *videos* is money this quarter.
- **Don't chase ad-supported content.** YouTube/TikTok clips are marketing for
  bookings, not a revenue line.

## Suggested 90-day plan

1. **Week 1–2:** showreel + landing page + wedding pitch page.
2. **Week 2–4:** outreach — 10 event agencies, 10 wedding planners, 3 conference
   organizers; apply to S+T+ARTS and one Portuguese grant.
3. **Month 2:** first paid shows; sell the print/video upsell at each; post every
   deliverable as content.
4. **Month 3:** soft-launch the music-video service (manual tier) with 3 discounted
   pilot artists; decide on self-serve based on demand.

**Revenue math for a modest first quarter:** 4 shows (avg €2,000) + 3 upsells
(avg €300) + 4 videos (avg €300) ≈ **€10,100**, before any grant lands.
