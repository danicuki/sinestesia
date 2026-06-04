defmodule Sinestesia.ImageGen do
  @moduledoc """
  Image generation dispatcher. Picks the provider based on `IMAGE_PROVIDER`:

    "fal"           → fal.ai Flux Schnell        (fastest, paid)
    "google"        → Google Imagen 4 Fast       (uses Gemini credits)
    "pollinations"  → Pollinations.ai (Flux)     (free, no auth)

  All providers return `{:ok, url_or_data_url} | {:error, reason}`.
  The frontend's TextureLoader handles both HTTPS URLs and `data:` URLs.
  """
  require Logger

  @spec generate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt) when is_binary(prompt) do
    provider = provider()

    case provider do
      :fal -> Sinestesia.ImageGen.Fal.generate(prompt)
      :google -> Sinestesia.ImageGen.Google.generate(prompt)
      :pollinations -> Sinestesia.ImageGen.Pollinations.generate(prompt)
    end
  end

  def provider do
    case System.get_env("IMAGE_PROVIDER", "fal") |> String.downcase() do
      "google" -> :google
      "pollinations" -> :pollinations
      _ -> :fal
    end
  end
end
