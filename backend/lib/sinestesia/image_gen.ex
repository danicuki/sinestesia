defmodule Sinestesia.ImageGen do
  @moduledoc """
  Image generation dispatcher. Picks the provider based on `IMAGE_PROVIDER`:

    "fal"           → fal.ai Flux Schnell/dev    (fast, paid)
    "local_sdxl"    → local SDXL Turbo img2img   (local, free, see local-sdxl/)
    "cloudflare"    → Workers AI: Flux schnell t2i + SDXL base img2img
                      (startup credits; real CFG so prompts steer content)
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

    if render_mode() == :t2i do
      case t2i(prompt) do
        {:ok, target_url, frames} ->
          {:ok, target_url, frames}

        {:ok, target_url} ->
          if is_binary(image_url) and image_url != "" and local_morph?() do
            # This local SDXL morph runs AFTER the cloud provider returned, so it
            # adds its own seconds on top. Record it separately (same process as
            # the caller's task) so the cloud provider isn't blamed for the local
            # morph's cost in the on-screen timings.
            morph_started = System.system_time(:millisecond)

            result =
              case Sinestesia.ImageGen.LocalSdxl.morph(image_url, target_url) do
                {:ok, local_url, frames} ->
                  {:ok, local_url, frames}

                _err ->
                  # Fallback to original cloud image without frames
                  {:ok, target_url, []}
              end

            Process.put(:morph_ms, System.system_time(:millisecond) - morph_started)
            result
          else
            {:ok, target_url, []}
          end

        error ->
          error
      end
    else
      img2img(prompt, image_url, opts)
    end
  end

  # T2I story mode (RENDER_MODE=t2i): EVERY frame is rendered from scratch
  # from the cumulative scene prompt — there is no img2img feedback loop, so
  # there is no generational drift ("psychedelic decay"). This is how the
  # original sample sequences (aquarela/cityscape/cosmic) were made: temporal
  # coherence comes from prompt overlap (scene list + same style every frame)
  # and the frontend's morphing, not from feeding images back into the model.
  defp t2i(prompt) do
    case provider() do
      :cloudflare -> Sinestesia.ImageGen.Cloudflare.text2img(prompt)
      :google -> Sinestesia.ImageGen.Google.generate(prompt)
      :pollinations -> Sinestesia.ImageGen.Pollinations.generate(prompt)
      :local_sdxl -> Sinestesia.ImageGen.LocalSdxl.generate(prompt, nil)
      # fal (img2img-only) renders via Flux Schnell.
      _ -> Sinestesia.ImageGen.Fal.generate(prompt)
    end
  end

  defp local_morph? do
    System.get_env("LOCAL_MORPH", "true") in ~w(true 1 yes)
  end

  defp img2img(prompt, image_url, opts) do
    case {provider(), image_url} do
      {:fal, url} when is_binary(url) and url != "" ->
        case Keyword.get(opts, :element) do
          el when is_binary(el) and el != "" ->
            placement = Keyword.get(opts, :placement, "center")
            mask_url = Sinestesia.ImageGen.Masks.get_mask(placement)
            Sinestesia.ImageGen.FalInpaint.generate(prompt, url, mask_url)

          _ ->
            Sinestesia.ImageGen.FalImg2Img.generate(prompt, url)
        end

      {:fal, _} ->
        Sinestesia.ImageGen.Fal.generate(prompt)

      {:local_sdxl, url} when is_binary(url) and url != "" ->
        Sinestesia.ImageGen.LocalSdxl.generate(
          prompt,
          url,
          Keyword.take(opts, [:camera, :element, :placement, :strength, :steps, :style_pass])
        )

      {:local_sdxl, _} ->
        Logger.info("[image_gen] bootstrap first frame locally via local SDXL text-to-image")
        Sinestesia.ImageGen.LocalSdxl.generate(bootstrap_composition(prompt), nil)

      {:cloudflare, url} when is_binary(url) and url != "" ->
        Sinestesia.ImageGen.Cloudflare.img2img(prompt, url)

      {:cloudflare, _} ->
        Sinestesia.ImageGen.Cloudflare.text2img(bootstrap_composition(prompt))

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

  @doc """
  `:img2img` (default) — each frame evolves the previous image.
  `:t2i` (RENDER_MODE=t2i) — each frame re-rendered from the full scene prompt.
  """
  def render_mode do
    case System.get_env("RENDER_MODE", "img2img") |> String.downcase() do
      "t2i" -> :t2i
      _ -> :img2img
    end
  end

  @doc """
  Record which route/model actually served this frame.

  `provider/0` only reports what is *configured*, and one provider can serve a
  frame from very different models: Cloudflare's fast 6-step SDXL-Lightning for
  the opening text-to-image frame, then the 20-step SD-1.5 img2img build for
  every frame after. Labelling both "cloudflare" made a 1.7s frame and a 6.9s
  frame look like the same thing. Called by the provider module that runs, and
  read by the pipeline task (same process) alongside the timings.
  """
  def note_route(route, model, steps) do
    Process.put(:image_route, %{route: route, model: model, steps: steps})
    :ok
  end

  @doc "Route/model recorded for the frame just generated, if the provider reported one."
  def last_route, do: Process.get(:image_route)

  def provider do
    case System.get_env("IMAGE_PROVIDER", "fal") |> String.downcase() do
      "google" -> :google
      "pollinations" -> :pollinations
      "local_sdxl" -> :local_sdxl
      "local" -> :local_sdxl
      "cloudflare" -> :cloudflare
      "cf" -> :cloudflare
      _ -> :fal
    end
  end
end
