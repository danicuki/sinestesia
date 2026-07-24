import type { Performance } from './provenance.js';

/**
 * Rarity that is *earned by the performance*, not assigned arbitrarily. Every
 * trait is derived from what actually happened on stage — the palette the
 * Director chose, how many brush-moments the song had, how long it ran — so a
 * collection across many shows develops natural, honest rarity.
 */

const PALETTE_WORDS = [
  'yellow', 'gold', 'amber', 'rose', 'pink', 'crimson', 'blue', 'azulejo',
  'indigo', 'sea', 'green', 'emerald', 'violet', 'white', 'black', 'orange',
];

const MOTIF_WORDS = [
  'sun', 'moon', 'star', 'castle', 'boat', 'sailing', 'seagull', 'bird',
  'wave', 'ocean', 'mountain', 'flower', 'city', 'rain', 'fire', 'forest',
];

function countMatches(text: string, vocab: string[]): string[] {
  const lower = text.toLowerCase();
  return vocab.filter((w) => lower.includes(w));
}

export function deriveTraits(p: Performance): Record<string, string | number> {
  const allPrompts = p.directorPrompts.join(' ');
  const palette = countMatches(allPrompts, PALETTE_WORDS);
  const motifs = countMatches(allPrompts, MOTIF_WORDS);

  const durationMs =
    p.timestamps.length >= 2
      ? Date.parse(p.timestamps.at(-1)!) - Date.parse(p.timestamps[0])
      : 0;

  return {
    venue: p.venue,
    strokes: p.directorPrompts.length, // Director prompts = brush-moments
    paletteSize: palette.length,
    dominantColor: palette[0] ?? 'unnamed',
    motifCount: motifs.length,
    signatureMotif: motifs[0] ?? 'abstract',
    durationSec: Math.round(durationMs / 1000),
    // Editions can layer on top of this; the master 1/1 is the rarest.
    rarity: rarityTier(palette.length, motifs.length),
  };
}

/** A simple, explainable tier from palette breadth + motif richness. */
function rarityTier(paletteSize: number, motifCount: number): string {
  const score = paletteSize + motifCount;
  if (score >= 7) return 'legendary';
  if (score >= 5) return 'rare';
  if (score >= 3) return 'uncommon';
  return 'common';
}
