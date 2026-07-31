defmodule Sinestesia.PerformanceFollower do
  @moduledoc """
  Locates where a live performance is inside a *known* script.

  The operator pastes the song's lyrics before it is sung (see the `lyrics` WS
  message). As each line is actually sung, STT hands us the confirmed text; this
  module matches that text against the pasted lines and reports which line was
  reached, so the pipeline can advance a cursor and reveal the frame it
  speculatively rendered for that line.

  Phase 1 follows the *lyrics* only. The interface is deliberately shaped to
  later fuse musical-structure (verse/chorus/bridge) and tempo signals behind
  the same `match/4` call without the pipeline caring how the position is found.

  ## Matching

  Singing is mostly sequential, so we only consider a small window around the
  current cursor: one line back (a repeated line / STT re-segmentation) through
  `:window` lines ahead (a skipped line). Similarity is the **overlap
  coefficient** on accent-folded word sets — `|A∩B| / min(|A|,|B|)` — which is
  robust to the two things STT does to lyrics: it drops/adds a few words, and it
  segments on its own boundaries (so a sung fragment is a subset of a script
  line, or vice versa), both of which keep the coefficient high. The best
  candidate above `:threshold` wins; ties break toward the nearest line *ahead*
  of the cursor, biasing forward progress.
  """

  @default_window 3
  @default_threshold 0.6

  @doc """
  Match a confirmed sung line against the script.

  `cursor` is the index of the last confirmed line (`-1` before the song
  starts). Returns `{:match, index}` for the best line at or ahead of the
  cursor whose similarity clears the threshold, or `:no_match` when the singer
  is off-script (an improvisation, or a line the pasted lyrics don't contain).

  Options: `:window` (lines to look ahead, default #{@default_window}),
  `:threshold` (0.0–1.0, default #{@default_threshold}).
  """
  @spec match(String.t(), [String.t()], integer(), keyword()) ::
          {:match, non_neg_integer()} | :no_match
  def match(sung, script, cursor, opts \\ [])
      when is_binary(sung) and is_list(script) and is_integer(cursor) do
    window = Keyword.get(opts, :window, @default_window)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    sung_set = tokens(sung)
    n = length(script)

    if MapSet.size(sung_set) == 0 or n == 0 do
      :no_match
    else
      lo = max(cursor - 1, 0)
      hi = min(cursor + window, n - 1)

      lo..hi
      |> Enum.filter(&(&1 >= 0 and &1 < n))
      |> Enum.map(fn i -> {i, similarity(sung_set, tokens(Enum.at(script, i)))} end)
      |> Enum.filter(fn {_i, s} -> s >= threshold end)
      |> Enum.sort_by(fn {i, s} -> {-s, forward_distance(i, cursor)} end)
      |> case do
        [{i, _s} | _] -> {:match, i}
        [] -> :no_match
      end
    end
  end

  @doc """
  Bulk catch-up, for after an eager pre-render: given EVERYTHING sung so far
  (not just the latest line), find the FURTHEST script line within the window
  that's plausibly been covered.

  This is a different question from `match/4`. `match/4` answers "which nearby
  candidate does this one just-sung line best match" and prefers the NEAREST
  line ahead of the cursor. Here the accumulated text may already contain
  several lines' worth of words, and preferring the nearest candidate would
  under-report how far the singer has actually gotten — so this scans forward
  from the cursor and takes the LAST line whose words are covered, not the
  first. Used once, right when an eagerly pre-rendered opening frame reveals,
  to position the cursor for ordinary per-line look-ahead to continue from.

  The scan stops at the first line that ISN'T covered, rather than taking the
  furthest covered line anywhere in the window. A performance moves through
  the lyrics in order, so a covered line with an UNCOVERED gap before it was
  never actually reached — it's a later repeat that happens to share words
  with what's been sung. `coverage/2`'s denominator is the candidate line
  alone, which makes a short line of common words (Fly Me To The Moon's "And
  let me sing forever more" against an opening that already contains "and",
  "let" and "me") cheap to clear by coincidence, so without the contiguity
  requirement one lucky hit eight lines ahead drags the cursor there and the
  look-ahead spends the rest of the song predicting lines nobody has sung
  yet. See HANDOFF.md gotcha #42.
  """
  @spec furthest_match(String.t(), [String.t()], integer(), keyword()) ::
          {:match, non_neg_integer()} | :no_match
  def furthest_match(sung_so_far, script, cursor, opts \\ [])
      when is_binary(sung_so_far) and is_list(script) and is_integer(cursor) do
    window = Keyword.get(opts, :window, @default_window)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    sung_set = tokens(sung_so_far)
    n = length(script)

    if MapSet.size(sung_set) == 0 or n == 0 do
      :no_match
    else
      lo = max(cursor + 1, 0)
      hi = min(cursor + window, n - 1)

      lo..hi
      |> Enum.filter(&(&1 >= 0 and &1 < n))
      |> Enum.take_while(fn i -> coverage(sung_set, tokens(Enum.at(script, i))) >= threshold end)
      |> case do
        [] -> :no_match
        indices -> {:match, Enum.max(indices)}
      end
    end
  end

  @doc """
  Does this one confirmed utterance already cover `line`?

  Same asymmetric measure `furthest_match/4` uses (what fraction of the
  CANDIDATE line's words appear in the sung text), asked about a single known
  line instead of scanned over a window. Used to tell "the singer is partway
  through a multi-line scene" apart from "the singer sang the whole scene in
  one breath" — `match/4` reports only the single best-scoring line, which for
  a two-line scene sung in one go is usually the FIRST of the two, not the
  last. See HANDOFF.md gotcha #44.
  """
  @spec covers?(String.t(), String.t(), keyword()) :: boolean()
  def covers?(sung, line, opts \\ []) when is_binary(sung) and is_binary(line) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    coverage(tokens(sung), tokens(line)) >= threshold
  end

  @doc "Normalize a raw lyrics payload (a list of lines, or one blob with newlines) into trimmed, non-empty lines."
  @spec normalize(term()) :: [String.t()]
  def normalize(text) when is_binary(text), do: text |> String.split(~r/\r?\n/) |> clean_lines()
  def normalize(lines) when is_list(lines), do: lines |> Enum.map(&to_string/1) |> clean_lines()
  def normalize(_), do: []

  defp clean_lines(lines) do
    lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # Overlap coefficient: 1.0 when one set is a subset of the other (the common
  # STT case where a sung fragment is part of a longer script line, or a merged
  # sung line contains a short one). Falls off as the two share fewer words.
  defp similarity(a, b) do
    denom = min(MapSet.size(a), MapSet.size(b))
    if denom == 0, do: 0.0, else: MapSet.size(MapSet.intersection(a, b)) / denom
  end

  # Prefer the nearest line ahead of the cursor; treat at/behind as far away so
  # a forward candidate of equal similarity always wins.
  defp forward_distance(i, cursor) when i > cursor, do: i - cursor
  defp forward_distance(i, cursor), do: 1_000 + (cursor - i)

  # What fraction of the CANDIDATE line's words appear in the accumulated sung
  # text. Deliberately asymmetric (unlike similarity/2's overlap coefficient,
  # which takes min() of the two sizes): the accumulated blob is expected to be
  # much bigger than any single candidate line, so what matters is whether the
  # WHOLE line is covered, not how the two sizes compare.
  defp coverage(sung_set, line_set) do
    denom = MapSet.size(line_set)
    if denom == 0, do: 0.0, else: MapSet.size(MapSet.intersection(sung_set, line_set)) / denom
  end

  # Lowercase, fold accents (STT and the pasted lyrics disagree on diacritics),
  # drop punctuation, collapse repeated letters, split to a word set.
  #
  # The collapse is what makes this work on SUNG input rather than spoken:
  # singers hold vowels, and the STT transcribes what it hears, so the same
  # word arrives as "castelooo", "castééelo", "cincooo", "fááácil", "papééél",
  # "céééu", "folhaaa". None of those are the script's token, and each miss
  # costs real matching headroom — measured on a live Aquarela run, the scene
  # ending "É fácil fazer um castelo" scored exactly 0.600 against a 0.6
  # threshold, clearing by a hair purely because "fácil" AND "castelo" were
  # both elongated. One more held vowel and the castle picture would not have
  # been shown at all. Collapsing takes that line to 1.000.
  #
  # Only runs of THREE or more collapse. Two-letter runs are left alone
  # because they are real words, not held notes — "moon", "ecoou", "carro",
  # "corro", "passa", "terra". Collapsing every run instead would fold each of
  # those into a different word ("corro" -> "coro"), and this very song opens
  # "Corro o lápis em torno da mão", so the collision is live, not theoretical.
  # (Both sides run through this same function, so an all-runs collapse would
  # still match a word against ITSELF; the damage is against the OTHER
  # candidate lines in the window, which is exactly what the follower is
  # trying to tell apart.)
  #
  # Three-plus is where a singer actually lives, and it composes correctly
  # with real doubles: "passaaa" keeps its "ss" and loses only the held "aaa".
  # Measured against the live transcripts, 3+ recovers the whole win the
  # all-runs version did on held vowels (0.600 -> 1.000 on the castle scene)
  # while leaving every real word distinct. It gives up a little where the STT
  # *doubles* a letter rather than the singer holding one ("réttas",
  # "fáciil": 1.000 -> 0.833), which still clears the threshold with room.
  defp tokens(text) do
    text
    |> String.downcase()
    |> fold_accents()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/(.)\1{2,}/u, "\\1")
    |> String.split(~r/\s+/, trim: true)
    |> MapSet.new()
  end

  defp fold_accents(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end
end
