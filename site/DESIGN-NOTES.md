# Sinestesia — design decisions

Three pages, one system:

- `Sinestesia-Artists.dc.html` — artist-facing landing page (entry point)
- `Sinestesia-Producers.dc.html` — venue / festival / activation argument
- `Sinestesia-Under-The-Hood.dc.html` — technical appendix (paper theme)
- `Sinestesia-Wordmark.dc.html` — identity sheet: mark, lockups, variants, rules
- `design-system.css` — canonical tokens

Each page is a single self-contained file: no build step, no CDN, no remote
fonts or scripts, minimal vanilla JS (one IntersectionObserver per page).

## Color

**Ink base, one warm accent.** The artwork is unpredictable and vivid, so the
brand is a frame, not a competitor. `#0C0B0F` is a near-black with a slight
violet lean — it reads as ink rather than switched-off screen, and any painting
placed on it looks intentional. Text is `#EDE7DE`, a warm off-white; pure white
on pure black is the look of a terminal, not a gallery.

The single accent is ochre `#E08A3C` — `oklch(0.72 0.126 62)`. Warm enough to
read as pigment, dark enough that filled buttons take near-black text
(`#14100B`) and stay legible on a phone at low brightness in a dark room.

Atmosphere layers (the soft blooms behind the hero) use violet and teal washes at
very low alpha. They are deliberately **not** tokens for UI color — nothing
interactive is ever violet or teal, so a real painting entering the frame never
argues with the interface.

The appendix flips to a warm paper theme (`#F5F1EA` / `#1A1720`) with the accent
darkened to `#A45B12` to hold 4.5:1. That is the "appendix of a beautiful book"
cue: same voice, different paper.

## Type

Display is **Georgia** (falling back through Iowan Old Style to Times). It is on
every machine, has real personality — high contrast, humanist, slightly literary
— and its italic is genuinely expressive, which is why every hero uses italic
for the emotional half of the headline. It is the opposite of the geometric
startup sans, and it costs zero bytes.

Body is the **Helvetica Neue / Helvetica / Arial** stack: neutral, dense,
extremely legible at 15–17px, and it disappears next to the serif.

Technical detail, labels, stage callouts and diagrams are **monospace** with wide
tracking (`0.14em`) in uppercase. That is the third voice: crew tape, cue sheet,
spec. It carries all the "this is engineered" signal so the prose never has to.

Scale is a soft 1.25–1.35 ratio with `clamp()` on everything above 21px, so the
hero is mobile-first by construction.

## Wordmark & mark — see `Sinestesia-Wordmark.dc.html`

**Mark: the overlap.** Two discs of equal size sitting 61% of a diameter apart — sharing 39% of their width —
one off-white (the voice), one ochre (the pigment). They are blended, not stacked:
`mix-blend-mode: plus-lighter` on ink, `multiply` on paper. The only new colour in
the mark is the lens where they cross, and it exists solely because the two
shapes meet. That is synesthesia stated structurally rather than illustrated, and
it is two circles — it survives 16px, embroidery, and a single-colour stage print
(both discs one ink at 55%; the overlap still reads).

**Wordmark: the two i's.** "Sinestesia" carries two i's, near-symmetrically placed.
Both are set in the accent, dropping two points of colour inside the word so the
crossing happens while you read it. Georgia, tracking pulled to −0.005em so the
word sets as one object next to the mark. Mono/one-colour variant: the i's go
solid, nothing else changes.

Clear space is one disc radius on every side. The ochre disc drifts a few percent
over 7s on the live site, so the overlap breathes — the accumulate principle at
logo scale; off under reduced motion. Favicon is the same two circles with
`mix-blend-mode: screen`, inlined as an SVG data URI at 32 and 16px.

## Motion: accumulate, never transition

One principle, applied everywhere: elements **arrive** — opacity 0 → 1 with a
14px rise and a 6px blur burning off over 1100ms on `cubic-bezier(.2,.7,.2,1)`,
staggered 90ms between siblings. That is paint soaking in, not a slide moving.
Nothing slides horizontally, nothing scales in, nothing fades out.

Background washes drift on a 26s loop — slower than anyone consciously notices,
which is how projected paint behaves in a room.

`prefers-reduced-motion` kills all of it: animations and transitions off,
revealed elements forced visible. Because the whole site is motion-based, this
is handled in the stylesheet *and* in JS (the reveal never arms itself).

## The hero moment

The first screen is: one line of type, then a framed 16:9 artifact, then the
transcript that produced it.

The artifact frame is a raised ink card with a 10px inset border — a canvas on a
wall, not a video player. Inside it sits the real animated WebP of a complete
song assembling. **Framing spec:** 16:9, full width of the 1180px column,
`border-radius: 8px` inside a 14px card, `aspect-ratio` locked so nothing shifts
while it loads. Autoplay, muted, looped, `poster` = the finished painting so the
first paint is already the payoff. A `LIVE · PAINTING` chip sits bottom-left
inside the frame; mono captions sit outside it (`PROJECTION FEED · 1920×1080`,
`SINGLE CANVAS · NO CUTS`) so the frame stays clean.

Directly beneath it, the sample transcript lines light one at a time on a 1.6s
cycle — the cause next to the effect. Together they say "a painting is growing
from a voice" before a word of copy is read. Swap `heroFraming` to `portrait`
(4:5) for phone-shot artifacts.

Both hero slots are currently striped placeholders with monospace instructions.
Drop the WebP in and delete the placeholder text.

## Azulejo

Used once, at low volume: the faint 4×4 grid in the "one canvas" panel, and the
dashed tick rule under the show-day timeline. Repeating hand-painted panels that
together make one picture is exactly the product, so the motif earns its place —
but at 6% alpha, as texture. No blue, no tile borders, no travel brochure.

## Honesty

No invented venues, artists, quotes or metrics. Two clearly-marked dashed
placeholder blocks (artist proof, venue proof) with instructions for what goes in
them and when. The latency table is labelled a design budget, not a benchmark.
The verifiable-inference section states plainly which part is still moving.

## Tweaks exposed

- Artists: `heroFraming` (cinema / portrait), `showProofSlot`
- Producers: `showProofSlot`
