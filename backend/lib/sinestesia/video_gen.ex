defmodule Sinestesia.VideoGen do
  @moduledoc """
  Registry of clip engines for motion mode. Every engine speaks the same
  contract — `spec/1` (rates, default resolution), `clamp_duration/1`
  (nearest billable clip length), `submit/3` (returns an awaitable ref),
  `await/3` (poll + download) — so `--motion-model` picks a backend the way
  `IMAGE_PROVIDER` picks an image one.

  Veo (Gemini credits) is the offline default; MiniMax via fal earns its
  keep only if this ever chases realtime (~3s per 5s clip, a property Veo
  doesn't have).
  """

  @engines %{
    "veo" => Sinestesia.VideoGen.GeminiVeo,
    "veo-fast" => Sinestesia.VideoGen.GeminiVeo,
    "veo-lite" => Sinestesia.VideoGen.GeminiVeo,
    "h3-max" => Sinestesia.VideoGen.FalMinimax,
    "h3" => Sinestesia.VideoGen.FalMinimax
  }

  def engine(name), do: Map.get(@engines, name)
  def names, do: Map.keys(@engines) |> Enum.sort()
end
