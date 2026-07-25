# Design brief — Sinestesia brand + landing site

**How to use this file:** hand the whole thing to the design agent as the prompt.
It is written to be self-contained — it assumes no access to this repo.

---

## The prompt

You are designing the brand and public landing site for **Sinestesia**.

### What Sinestesia actually is

A live performance instrument. A singer performs; the system listens to the
voice and the music, understands the lyrics as they are sung, and **paints a
single picture that grows across the whole song** — projected behind the artist,
in real time. It is not a slideshow and not a video filter: one canvas, one
continuous painting, each new line adding to what is already there.

When the song ends, the painting is minted as a token that carries proof of the
exact live moment that made it — the transcript, every instruction the AI
director gave, and the timestamps. The audience scans a QR code on the
projection and keeps a free print of that moment.

The one-line positioning: **it eternalizes and augments a live musical moment.**

### Who it is for (two distinct audiences, one brand)

1. **Artists / musicians** — solo performers, bands, DJs. They want their show to
   look extraordinary without hiring a VJ, and they want something their fans can
   take home. Emotional register: *your voice becomes visible.* Sells on wonder
   and on intimacy with the audience.

2. **Festival & venue producers** — bookers, production leads, brand-activation
   agencies. They want a differentiated act, a reliable technical rider, and
   something audiences photograph and post. Emotional register: *a stage moment
   nobody has seen before, that ships with a spec sheet.* Sells on credibility,
   reliability, and audience engagement metrics.

A third audience visits during the launch window: **hackathon judges and
technical people.** They should be able to reach depth in one click, but must
never be the primary voice of the page — do not let the landing page become a
crypto page. The technology is the *how*, never the pitch.

### What already exists (do not discard, elevate)

Two hand-built HTML pages exist with a watercolor feel:

- `index.html` — producer-facing, headline direction *"We Paint Your Show"*
- `artists.html` — artist-facing

Treat these as a rough sketch of the right instinct: soft, painterly, warm. The
redesign should keep that spirit and give it a real system — type scale, color
tokens, spacing rhythm, components — rather than one-off styling.

### Brand direction to develop

Give me a coherent identity, not a mood board. Specifically:

- **Name treatment / wordmark.** "Sinestesia" (Portuguese/Spanish for
  synesthesia — the condition where senses cross, where sound *has* color). The
  name is the whole concept; the wordmark should carry a hint of that crossing —
  sound becoming image — without being literal (no ears, no eyeballs, no
  music-note clip art).
- **Color.** The work itself is unpredictable — the paintings are whatever the
  song makes them. So the brand needs to be a *frame*, not a competitor: quiet
  and confident, letting vivid artwork sit inside it without clashing. Consider a
  deep near-black or ink base with one warm accent. Must work in a darkened
  venue on a phone, which is where most people will actually see it.
- **Type.** One expressive face for headlines with real personality (this is an
  art product, not a SaaS dashboard) and one highly legible face for body and
  technical detail. Avoid the generic startup geometric sans.
- **Motion principle.** One idea, used consistently: things *accumulate* rather
  than appear. That is literally what the product does — every animation on the
  site should feel like paint being added, never like a slide transition.
- **Lisbon note (optional, use with restraint).** It launches at ETHGlobal
  Lisbon, and Portuguese *azulejo* tile has an obvious affinity — repeating
  hand-painted panels that together tell one story. Use it as a subtle texture or
  grid motif if it strengthens the work. Skip it entirely if it makes the brand
  look like a travel brochure. Your call.

### Deliverables

1. **Design system**: color tokens (light + dark), type scale, spacing scale,
   radii, elevation, motion timings. Delivered as CSS custom properties.
2. **Wordmark + favicon**, plus a monochrome variant for dark projection.
3. **Landing page — artists** (full responsive layout, mobile-first).
4. **Landing page — producers** (same system, different argument and proof).
5. **Shared components**: nav, hero with video/artwork slot, feature block,
   proof/credibility strip, FAQ, footer, CTA.
6. **The hero moment.** The single most important asset: the first three seconds
   must communicate "a painting is growing from a voice." Design around an
   embedded looping artifact (we have real animated WebP files of complete songs
   — a painting assembling itself beat by beat). Specify exactly how it is framed,
   sized, and what plays behind or beside it.
7. **A "how it works" section** that a non-technical musician understands: voice
   → understanding → painting → a keepsake for the room. Three or four steps,
   visual, no jargon, no blockchain vocabulary above the fold.
8. **One technical-depth page or section** for judges and engineers: the
   architecture, the verifiable-AI angle, the provenance proof. It should feel
   like the appendix of a beautiful book, not the front cover.

### Hard constraints

- Static HTML + CSS (+ minimal vanilla JS). No React, no build step, no Tailwind.
- **Fully self-contained**: no CDN links, no external fonts, no remote scripts.
  Inline the CSS, embed fonts as data URIs or use a well-chosen system stack.
- Responsive; the page body must never scroll horizontally. Wide elements scroll
  inside their own container.
- Respect `prefers-reduced-motion` — the site is motion-heavy by concept, so this
  matters more than usual.
- Accessible contrast in both themes. Real focus states. Semantic headings.
- Fast: this will be opened on venue wifi and on judges' phones.

### Tone of voice

Confident, warm, specific. Short sentences. Concrete nouns.

Write like someone who has actually stood on a stage — not like a deck. Avoid:
"revolutionary", "cutting-edge", "leveraging AI", "Web3-powered", "seamlessly".
Never oversell what it does: it paints from what it hears, and sometimes what it
paints is surprising — that is the charm, not a bug to hide.

Claims must stay honest. Do not invent venues, artists, press quotes, metrics or
testimonials. If a section needs social proof that does not exist yet, design the
slot and leave it clearly marked as a placeholder.

### Deliver as

Separate files per page plus one shared `design-system.css`, in a structure that
can be dropped into a static host. Include brief notes on the decisions —
especially color and type — so they can be defended and extended.
