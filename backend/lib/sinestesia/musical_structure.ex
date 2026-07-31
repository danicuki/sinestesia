defmodule Sinestesia.MusicalStructure do
  @moduledoc """
  Derives a song's structure — verse / chorus / bridge / outro — from the
  operator's pasted lyrics, so the pipeline knows *where in the song* the singer
  is (not just which line) and can react when the chorus returns.

  This is Phase 2's reliable spine. Live audio (tempo, energy) can corroborate it
  (see `Sinestesia.Tempo`), but the structure itself is read from the lyrics,
  which the operator already provides for look-ahead — no fragile online MIR
  needed. The single requirement on the operator is to **separate stanzas with a
  blank line**; a repeated stanza is the chorus.

  ## Output

      analyze(text) => %{
        lines: ["line1", "line2", ...],           # flat, in order (matches the follower's cursor)
        sections: [%{id: 0, label: :verse, occurrence: 1, line_start: 0, line_end: 1,
                     size: 2, sig: "..."}, ...],
        line_section: %{0 => 0, 1 => 0, 2 => 1, ...}  # flat line index => section id
      }

  `label` is one of `:verse | :chorus | :bridge | :outro`. `occurrence` counts how
  many times a stanza with the same normalized text has appeared so far (so the
  2nd time the chorus is sung, its section carries `occurrence: 2`).
  """

  @type section :: %{
          id: non_neg_integer(),
          label: :verse | :chorus | :bridge | :outro,
          occurrence: pos_integer(),
          line_start: non_neg_integer(),
          line_end: non_neg_integer(),
          size: pos_integer(),
          sig: String.t()
        }

  @doc """
  Analyze pasted lyrics into a structure map. Accepts the raw text (preferred —
  blank lines delimit stanzas) or a flat list of lines (no stanza info, so the
  whole thing is one verse).
  """
  @spec analyze(String.t() | [String.t()] | nil) :: %{
          lines: [String.t()],
          sections: [section()],
          line_section: %{optional(non_neg_integer()) => non_neg_integer()}
        }
  def analyze(nil), do: empty()

  def analyze(text) when is_binary(text) do
    stanzas =
      text
      |> String.split(~r/\r?\n/)
      |> chunk_by_blank()
      |> Enum.reject(&(&1 == []))

    build(stanzas)
  end

  def analyze(lines) when is_list(lines) do
    clean =
      lines |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    # A flat list carries no stanza boundaries, so it is one section.
    if clean == [], do: empty(), else: build([clean])
  end

  @doc "Section id covering a flat line index, or nil if out of range."
  @spec section_index_at(map(), integer()) :: non_neg_integer() | nil
  def section_index_at(%{line_section: ls}, line_index), do: Map.get(ls, line_index)

  @doc "The full section map covering a flat line index, or nil."
  @spec section_at(map(), integer()) :: section() | nil
  def section_at(%{sections: sections} = struct, line_index) do
    case section_index_at(struct, line_index) do
      nil -> nil
      id -> Enum.at(sections, id)
    end
  end

  @doc "The section label at a flat line index, or nil."
  @spec label_at(map(), integer()) :: atom() | nil
  def label_at(struct, line_index) do
    case section_at(struct, line_index) do
      nil -> nil
      %{label: label} -> label
    end
  end

  @doc """
  True when moving from `prev` to `curr` crosses a section boundary (entering the
  first section counts as a boundary). Used to fire a section-change reaction.
  """
  @spec boundary?(map(), integer(), integer()) :: boolean()
  def boundary?(struct, prev, curr) do
    cur_id = section_index_at(struct, curr)
    cur_id != nil and section_index_at(struct, prev) != cur_id
  end

  @doc """
  A short natural-language hint for a section, meant to be appended to the line
  handed to the Director — the same way `melody_hint` colors a call with vocal
  mood — so it knows structurally where the song is.

  Deliberately does NOT try to dictate what a returning chorus should look like:
  the Director already holds the whole conversation (story mode is multi-turn),
  so it already has that memory. The hint just tells it "this is that moment
  again" and lets its own context supply the echo.
  """
  @spec hint(section() | nil) :: String.t()
  def hint(nil), do: ""
  def hint(%{label: :chorus, occurrence: 1}), do: " [chorus begins]"

  def hint(%{label: :chorus, occurrence: n}) when n > 1,
    do: " [chorus returns (##{n}) — echo its established imagery]"

  def hint(%{label: :bridge}), do: " [bridge — a shift in the scene]"
  def hint(%{label: :outro}), do: " [song's outro]"
  def hint(_), do: ""

  ## Internals

  defp empty, do: %{lines: [], sections: [], line_section: %{}}

  # Group consecutive non-blank lines into stanzas, split on blank lines.
  defp chunk_by_blank(raw_lines) do
    raw_lines
    |> Enum.map(&String.trim/1)
    |> Enum.chunk_while(
      [],
      fn line, acc ->
        if line == "", do: {:cont, Enum.reverse(acc), []}, else: {:cont, [line | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp build(stanzas) do
    # Flat line list + per-section line ranges, in order.
    {sections0, flat, _offset} =
      Enum.reduce(stanzas, {[], [], 0}, fn stanza_lines, {secs, flat, offset} ->
        size = length(stanza_lines)

        sec = %{
          lines: stanza_lines,
          line_start: offset,
          line_end: offset + size - 1,
          size: size,
          sig: signature(stanza_lines)
        }

        {[sec | secs], flat ++ stanza_lines, offset + size}
      end)

    sections0 = Enum.reverse(sections0)
    counts = Enum.frequencies_by(sections0, & &1.sig)
    chorus_sig = pick_chorus_sig(sections0, counts)

    {labeled, _seen} =
      Enum.map_reduce(Enum.with_index(sections0), %{seen_chorus?: false, occ: %{}}, fn {sec, id},
                                                                                       acc ->
        occ = Map.get(acc.occ, sec.sig, 0) + 1
        last? = id == length(sections0) - 1
        label = label_for(sec, chorus_sig, counts, acc.seen_chorus?, last?)

        labeled = Map.merge(sec, %{id: id, label: label, occurrence: occ})
        seen_chorus? = acc.seen_chorus? or label == :chorus
        {labeled, %{seen_chorus?: seen_chorus?, occ: Map.put(acc.occ, sec.sig, occ)}}
      end)

    line_section =
      labeled
      |> Enum.flat_map(fn sec -> for i <- sec.line_start..sec.line_end, do: {i, sec.id} end)
      |> Map.new()

    %{lines: flat, sections: labeled, line_section: line_section}
  end

  # The chorus is the stanza whose normalized text repeats the most (≥2). Ties go
  # to the earliest-appearing stanza. No repeat → no chorus.
  defp pick_chorus_sig(sections, counts) do
    repeated = for %{sig: sig} <- sections, Map.get(counts, sig, 0) >= 2, do: sig

    case repeated do
      [] ->
        nil

      _ ->
        # Preserve first-appearance order (Enum.uniq keeps first), then take the
        # one with the highest count.
        repeated
        |> Enum.uniq()
        |> Enum.max_by(&Map.get(counts, &1))
    end
  end

  defp label_for(%{sig: sig}, chorus_sig, _counts, _seen, _last) when sig == chorus_sig,
    do: :chorus

  defp label_for(%{sig: sig, size: size}, _chorus_sig, counts, seen_chorus?, last?) do
    cond do
      # A repeated non-chorus stanza (e.g. a pre-chorus) reads as a verse.
      Map.get(counts, sig, 0) >= 2 -> :verse
      not seen_chorus? -> :verse
      last? and size <= 2 -> :outro
      true -> :bridge
    end
  end

  # Normalized stanza signature: what makes two stanzas "the same" chorus.
  defp signature(lines) do
    lines
    |> Enum.map(&normalize_line/1)
    |> Enum.join("\n")
  end

  defp normalize_line(line) do
    line
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
