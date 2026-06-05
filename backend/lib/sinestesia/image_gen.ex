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

  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    image_url = Keyword.get(opts, :image_url)

    case {provider(), image_url} do
      {:fal, url} when is_binary(url) and url != "" ->
        Sinestesia.ImageGen.FalImg2Img.generate(prompt, url)

      {:fal, _} ->
        Sinestesia.ImageGen.Fal.generate(prompt)

      {:google, _} ->
        Sinestesia.ImageGen.Google.generate(prompt)

      {:pollinations, _} ->
        Sinestesia.ImageGen.Pollinations.generate(prompt)
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
