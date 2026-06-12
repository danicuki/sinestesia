defmodule Sinestesia.ImageGen do
  @moduledoc """
  Image generation dispatcher. Picks the provider based on `IMAGE_PROVIDER`:

    "fal"           → fal.ai Flux Schnell/dev    (fast, paid)
    "local_sdxl"    → local SDXL Turbo img2img   (local, free, see local-sdxl/)
    "google"        → Google Imagen 4 Fast       (uses Gemini credits)
    "pollinations"  → Pollinations.ai (Flux)     (free, no auth)

  Providers return `{:ok, url_or_data_url} | {:error, reason}`. The local
  SDXL sidecar additionally returns `{:ok, url, frames}` where `frames` is a
  latent-morph sequence ending on `url` (see PROTOCOL.md `image.frames`).
  The frontend's TextureLoader handles both HTTPS URLs and `data:` URLs.

  Note: `local_sdxl` is img2img-only. When no previous image is available
  (very first frame of a session), we fall back to `fal` Flux Schnell for
  the opening shot, then switch to local SDXL for the rest. This avoids
  doing text-to-image on the local sidecar (which would require loading a
  second pipeline).
  """
  require Logger

  @spec generate(String.t(), keyword()) ::
          {:ok, String.t()} | {:ok, String.t(), [String.t()]} | {:error, term()}
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    image_url = Keyword.get(opts, :image_url)

    case {provider(), image_url} do
      {:fal, url} when is_binary(url) and url != "" ->
        Sinestesia.ImageGen.FalImg2Img.generate(prompt, url)

      {:fal, _} ->
        Sinestesia.ImageGen.Fal.generate(prompt)

      {:local_sdxl, url} when is_binary(url) and url != "" ->
        Sinestesia.ImageGen.LocalSdxl.generate(
          prompt,
          url,
          Keyword.take(opts, [:camera, :element, :placement, :strength, :steps, :style_pass])
        )

      {:local_sdxl, _} ->
        # First frame: local SDXL sidecar only does img2img. Bootstrap with
        # Flux Schnell on fal (cheap, fast), then everything after stays local.
        Logger.info("[image_gen] bootstrap first frame via fal Schnell (local SDXL is img2img-only)")
        Sinestesia.ImageGen.Fal.generate(bootstrap_composition(prompt))

      {:google, _} ->
        Sinestesia.ImageGen.Google.generate(prompt)

      {:pollinations, _} ->
        Sinestesia.ImageGen.Pollinations.generate(prompt)
    end
  end

  # The first frame anchors the whole song: every img2img frame inherits its
  # low-frequency structure. A poster-like opening (centered subject, radial
  # rays) leaves no room for the scene to grow — new elements get squeezed
  # into corners for the rest of the performance. Force a composition with
  # space to build into.
  defp bootstrap_composition(prompt) do
    prompt <>
      ", wide landscape composition with a clear horizon line, plenty of empty sky and open ground, subject small and off-center"
  end

  def provider do
    case System.get_env("IMAGE_PROVIDER", "fal") |> String.downcase() do
      "google" -> :google
      "pollinations" -> :pollinations
      "local_sdxl" -> :local_sdxl
      "local" -> :local_sdxl
      _ -> :fal
    end
  end
end
