defmodule Sinestesia.Tempo do
  @moduledoc """
  Smooths the browser's raw onset-interval tempo estimate (`fast_features`,
  `tempo_estimate`) into a stable BPM for the structure HUD.

  This is deliberately modest: a solo voice has no drum track, the browser-side
  estimator (median inter-onset interval over a handful of syllable onsets) is
  coarse, and singing rubato means the "true" tempo drifts constantly. Per
  CLAUDE.md, an atmosphere signal that's honestly `nil` beats one that's
  confidently wrong — so this module's whole job is to say "unknown" more often
  than it says a number, and never let a single noisy reading swing the estimate.

  It never feeds provenance or the mint. It only ever informs the `structure`
  push (a HUD readout) and, loosely, corroborates lyric-derived section timing.
  """

  # Singing tempo is very rarely outside this band; a raw reading beyond it is
  # almost always an onset-detector artifact (a sustained vowel's vibrato, a
  # consonant burst), not a real tempo — reject it rather than let it in.
  @min_bpm 50
  @max_bpm 200
  # Exponential smoothing weight for a new, plausible reading. Low: several
  # consistent readings in a row should be needed to move the displayed number.
  @alpha 0.25
  # A reading older than this is not "the current tempo" anymore — the singer
  # may have paused, stopped, or the estimator lost lock. Age out to unknown
  # rather than keep displaying a frozen, increasingly wrong number.
  @max_age_ms 8_000

  @type reading :: %{bpm: number() | nil, at: integer()}

  @doc """
  Fold one raw reading into the smoothed state.

  `prev` is `%{bpm: number() | nil, at: integer()}` (`at` in ms, `0`/`nil` bpm
  meaning "no estimate yet"). `raw_bpm` is the browser's latest estimate (may be
  `nil`, non-numeric, or implausible — all treated as "no usable reading this
  tick"). `now` is the current time in ms.

  Returns the new `%{bpm:, at:}`. `bpm` is `nil` whenever there is no current
  confident estimate (first call, implausible/missing reading with no live prior,
  or a prior reading that has aged out).
  """
  @spec smooth(reading(), term(), integer()) :: reading()
  def smooth(prev, raw_bpm, now) do
    prev = normalize(prev)

    if plausible?(raw_bpm) do
      bpm =
        case prev.bpm do
          nil -> raw_bpm * 1.0
          p -> p + (raw_bpm - p) * @alpha
        end

      %{bpm: bpm, at: now}
    else
      age_out(prev, now)
    end
  end

  @doc "Whether a raw BPM value is in the plausible singing-tempo band."
  @spec plausible?(term()) :: boolean()
  def plausible?(bpm) when is_number(bpm), do: bpm >= @min_bpm and bpm <= @max_bpm
  def plausible?(_), do: false

  @doc "The current BPM rounded for display, or nil if there is no confident estimate."
  @spec display(reading()) :: integer() | nil
  def display(%{bpm: nil}), do: nil
  def display(%{bpm: bpm}) when is_number(bpm), do: round(bpm)
  def display(_), do: nil

  defp normalize(%{bpm: _, at: _} = r), do: r
  defp normalize(_), do: %{bpm: nil, at: 0}

  defp age_out(%{bpm: nil} = prev, _now), do: prev

  defp age_out(%{bpm: _, at: at} = prev, now) do
    if now - at > @max_age_ms, do: %{bpm: nil, at: now}, else: prev
  end
end
