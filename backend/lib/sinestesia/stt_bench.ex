defmodule Sinestesia.SttBench do
  @moduledoc """
  Scoring for `mix sinestesia.bench.stt` — pure functions, no I/O.

  Three questions, because "accuracy" alone picks the wrong engine for a
  stage:

    * **How right is the text?** Word error rate against the song's real
      lyrics, on the same normalization the follower uses (case, accents,
      punctuation, held vowels folded — "castelooo" is not an error, it is a
      singer).
    * **How late is it?** Each transcript event is placed against a TIMED
      anchor (a slow, careful offline transcription with word timestamps):
      the latest sung word the event already contains tells how far behind
      the voice it arrived. Finals matter most — reveals are gated on them.
    * **Would the show follow it?** The finals are fed to
      `Sinestesia.PerformanceFollower` against the reference lines, exactly
      the matcher the pipeline uses to reveal pre-rendered frames: the share
      of lines it confirms, and how long after each line ENDED it did.
  """

  alias Sinestesia.PerformanceFollower

  @doc """
  Ordered word tokens under the follower's normalization: lowercase, accents
  folded, punctuation dropped, runs of three or more letters collapsed.
  """
  @spec tokens(String.t()) :: [String.t()]
  def tokens(text) when is_binary(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/(.)\1{2,}/u, "\\1")
    |> String.split(~r/\s+/, trim: true)
  end

  @doc """
  Word error rate of `hyp` against `ref` (token lists): (S + D + I) / N.
  Returns the counts too, so a corpus total can be word-weighted.
  """
  @spec wer([String.t()], [String.t()]) :: %{
          wer: float() | nil,
          errors: non_neg_integer(),
          n: non_neg_integer()
        }
  def wer(ref, hyp) do
    n = length(ref)
    errors = edit_distance(ref, hyp)
    %{wer: if(n == 0, do: nil, else: errors / n), errors: errors, n: n}
  end

  # Levenshtein over tokens, one row at a time.
  defp edit_distance(a, []), do: length(a)
  defp edit_distance([], b), do: length(b)

  defp edit_distance(a, b) do
    b = List.to_tuple(b)
    m = tuple_size(b)
    first = Enum.to_list(0..m)

    a
    |> Enum.with_index(1)
    |> Enum.reduce(first, fn {x, i}, prev ->
      prev_t = List.to_tuple(prev)

      {row, _} =
        Enum.reduce(1..m, {[i], i}, fn j, {acc, left} ->
          sub = elem(prev_t, j - 1) + if(x == elem(b, j - 1), do: 0, else: 1)
          v = min(sub, min(elem(prev_t, j) + 1, left + 1))
          {[v | acc], v}
        end)

      Enum.reverse(row)
    end)
    |> List.last()
  end

  @doc """
  Best LOCAL alignment (Smith-Waterman) of token lists `a` and `b`, with fuzzy
  word equality (held notes and one-letter STT slips still pair up). Returns
  the matched index pairs `[{i, j}]`, in order — empty when nothing aligns.

  Local, not global, because both uses need free ends: a transcript event is
  a fragment of the song, and a clip is a fragment of the lyrics.

  When two placements score the same (a repeated chorus), `prefer: :last`
  (the default) keeps the later one in `b` — for an event, the most recent
  occurrence is the one that was just sung; `prefer: :first` keeps the earlier.
  """
  @spec local_align([String.t()], [String.t()], keyword()) :: [
          {non_neg_integer(), non_neg_integer()}
        ]
  def local_align(a, b, opts \\ [])
  def local_align([], _, _), do: []
  def local_align(_, [], _), do: []

  def local_align(a, b, opts) do
    later? = Keyword.get(opts, :prefer, :last) == :last
    at = List.to_tuple(a)
    bt = List.to_tuple(b)
    n = tuple_size(at)
    m = tuple_size(bt)

    {h, best} =
      Enum.reduce(1..n, {%{}, {0, 0, 0}}, fn i, {h, best} ->
        Enum.reduce(1..m, {h, best}, fn j, {h, {bs, _, _} = best} ->
          diag = Map.get(h, {i - 1, j - 1}, 0) + score(elem(at, i - 1), elem(bt, j - 1))
          up = Map.get(h, {i - 1, j}, 0) - 1
          left = Map.get(h, {i, j - 1}, 0) - 1
          v = Enum.max([0, diag, up, left])
          h = if v > 0, do: Map.put(h, {i, j}, v), else: h
          better? = v > bs or (later? and v > 0 and v == bs)
          {h, if(better?, do: {v, i, j}, else: best)}
        end)
      end)

    case best do
      {0, _, _} -> []
      {_, i, j} -> traceback(h, at, bt, i, j, [])
    end
  end

  defp traceback(h, at, bt, i, j, acc) do
    v = Map.get(h, {i, j}, 0)

    cond do
      v == 0 or i == 0 or j == 0 ->
        acc

      v == Map.get(h, {i - 1, j - 1}, 0) + score(elem(at, i - 1), elem(bt, j - 1)) ->
        acc = if same?(elem(at, i - 1), elem(bt, j - 1)), do: [{i - 1, j - 1} | acc], else: acc
        traceback(h, at, bt, i - 1, j - 1, acc)

      v == Map.get(h, {i - 1, j}, 0) - 1 ->
        traceback(h, at, bt, i - 1, j, acc)

      true ->
        traceback(h, at, bt, i, j - 1, acc)
    end
  end

  defp score(x, y), do: if(same?(x, y), do: 2, else: -1)

  defp same?(x, x), do: true

  # One letter off counts as the same word from four letters up ("retas" /
  # "retaz", "chuva" / "chova"), two from eight — short words must match
  # exactly, or "se"/"te"/"de" would all pair with each other.
  defp same?(x, y) do
    n = min(String.length(x), String.length(y))
    n >= 4 and edit_distance(String.graphemes(x), String.graphemes(y)) <= if(n >= 8, do: 2, else: 1)
  end

  @doc """
  Where a clip sits inside the full lyrics: aligns the anchor transcript's
  tokens to the lyric tokens and returns the `{first, last}` lyric-token span
  it covers, or `nil` when they don't align at all.
  """
  @spec locate([String.t()], [String.t()]) :: {non_neg_integer(), non_neg_integer()} | nil
  def locate(anchor_tokens, lyric_tokens) do
    case local_align(anchor_tokens, lyric_tokens, prefer: :first) do
      [] -> nil
      pairs -> {pairs |> Enum.map(&elem(&1, 1)) |> Enum.min(), pairs |> Enum.map(&elem(&1, 1)) |> Enum.max()}
    end
  end

  @doc """
  Latency of each transcript event behind the voice, in ms.

  `events` are `%{t: ms_since_stream_start, text: ...}`; `anchor` is the timed
  word list `[%{token: t, end: seconds}]`. For each event, its tokens are
  aligned to the anchor words that had ALREADY been sung when it arrived (an
  STT can't transcribe the future; the 0.5s slack absorbs anchor timing
  error); the last anchor word it contains gives `t - end`. Events too short
  or too wrong to place are skipped, not guessed — and so is an event that
  adds no word beyond the previous one (a cumulative partial re-sent while
  the singer holds a note), which would otherwise measure the engine's
  re-send cadence instead of the word.
  """
  @spec lags([%{t: number(), text: String.t()}], [%{token: String.t(), end: number()}]) :: [
          number()
        ]
  def lags(events, anchor) do
    anchor_t = List.to_tuple(anchor)

    # One sample per event that brings a NEW word. Cumulative partials
    # re-send the phrase so far — ElevenLabs repeats the same text every
    # second while the singer holds a note — and crediting a repeat against
    # the word it last added would measure the re-send cadence, not how long
    # the word took to appear.
    events
    |> Enum.reduce({[], -1}, fn %{t: t, text: text}, {acc, last} ->
      toks = tokens(text)

      sung =
        anchor
        |> Enum.with_index()
        |> Enum.filter(fn {w, _} -> w.end * 1000 <= t + 500 end)

      window = Enum.take(sung, -80)

      offset =
        case window do
          [{_, i} | _] -> i
          [] -> 0
        end

      pairs = local_align(toks, Enum.map(window, fn {w, _} -> w.token end))
      needed = min(2, length(toks))

      if length(pairs) >= needed and needed > 0 do
        {_, j} = List.last(pairs)
        at = offset + j

        if at > last,
          do: {[t - elem(anchor_t, at).end * 1000 | acc], at},
          else: {acc, last}
      else
        {acc, last}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  Feed the finals to the follower against the reference lines, the way the
  pipeline does: `match/4` for the line just sung, then `covers?/3` for any
  following lines the same utterance also contains (a breath can carry two).

  Returns `%{confirmed: n, lines: total, delays: [ms after the line ended]}`.
  `line_ends` holds each line's last-word time in seconds (nil if unknown).
  """
  @spec follow([%{t: number(), text: String.t()}], [String.t()], [number() | nil]) :: map()
  def follow(finals, lines, line_ends) do
    {_cursor, confirmed} =
      Enum.reduce(finals, {-1, %{}}, fn %{t: t, text: text}, {cursor, acc} ->
        case PerformanceFollower.match(text, lines, cursor) do
          {:match, i} when i > cursor ->
            last = extend(text, lines, i)
            acc = Enum.reduce(i..last, acc, &Map.put_new(&2, &1, t))
            {last, acc}

          _ ->
            {cursor, acc}
        end
      end)

    ends = List.to_tuple(line_ends)

    delays =
      for {i, t} <- confirmed, e = elem(ends, i), e != nil, do: t - e * 1000

    %{confirmed: map_size(confirmed), lines: length(lines), delays: Enum.sort(delays)}
  end

  defp extend(text, lines, i) do
    if i + 1 < length(lines) and PerformanceFollower.covers?(text, Enum.at(lines, i + 1)),
      do: extend(text, lines, i + 1),
      else: i
  end

  @doc "Percentile (0..100) of a list of numbers; nil for an empty list."
  @spec pct([number()], number()) :: number() | nil
  def pct([], _p), do: nil

  def pct(xs, p) do
    s = Enum.sort(xs)
    k = (length(s) - 1) * p / 100
    lo = floor(k)
    hi = min(lo + 1, length(s) - 1)
    Enum.at(s, lo) + (Enum.at(s, hi) - Enum.at(s, lo)) * (k - lo)
  end
end
