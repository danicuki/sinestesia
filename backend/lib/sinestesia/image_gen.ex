defmodule Sinestesia.ImageGen do
  @moduledoc """
  Image generation dispatcher. Two independent switches decide what runs:

  `IMAGE_PROVIDER` — who renders:

    "fal"           → fal.ai Flux Schnell (t2i) / Flux dev (i2i)  (fast, paid)
    "cloudflare"    → Workers AI: SDXL-Lightning t2i + SD-1.5 i2i (cheap)
    "google"        → Google Imagen 4 Fast                        (Gemini credits)
    "pollinations"  → Pollinations.ai (Flux)                      (free, no auth)
    "local_sdxl"    → local SDXL Turbo sidecar                    (free, see local-sdxl/)

  `RENDER_MODE` — how each frame relates to the last:

    "i2i" (default) → the frame evolves the previous image: continuity, but
                      generational drift, and markedly slower per frame.
    "t2i"           → the frame is rendered from the scene prompt alone: no
                      drift, faster, continuity comes from prompt overlap and
                      the frontend's morphing.

  These are two questions, not one — every provider does both. See
  `render_mode/0` for why the codebase now says `t2i`/`i2i` and nothing else.

  Providers return `{:ok, url_or_data_url} | {:error, reason}`. The local
  SDXL sidecar additionally returns `{:ok, url, frames}` where `frames` is a
  latent-morph sequence ending on `url` (see PROTOCOL.md `image.frames`).
  The frontend's TextureLoader handles both HTTPS URLs and `data:` URLs.

  Note: `local_sdxl` is i2i-only. When no previous image is available (very
  first frame of a session), we fall back to `fal` Flux Schnell for the opening
  shot, then switch to local SDXL for the rest. This avoids doing
  text-to-image on the local sidecar (which would require loading a second
  pipeline).
  """
  require Logger

  @doc """
  What each provider can actually do.

  `IMAGE_PROVIDER`, `RENDER_MODE` and `COMPOSE_MODE` are three independent
  switches, but not every combination exists. Imagen and Pollinations have no
  image-to-image endpoint at all; only fal and the local sidecar can inpaint a
  masked region. Asking for something a provider can't do used to be accepted
  in silence: the previous frame and the placement were simply dropped on the
  floor, and story mode's `NEW: <element> | POS: <pos>` deltas — which only
  mean anything to an inpainter — became the *entire* prompt for an
  independent text-to-image render. The result is a song of isolated objects
  on unrelated canvases: a sun, then a hand, then an umbrella, nothing
  accumulating, the style re-interpreted from scratch every frame.

  So capabilities are declared, and `render_mode/0` and
  `Sinestesia.Director.compose?/0` resolve the request against them. See
  `Sinestesia.Config.conflicts/0` for how that's reported at boot.
  """
  @capabilities %{
    fal: %{t2i: true, i2i: true, inpaint: true},
    cloudflare: %{t2i: true, i2i: true, inpaint: false},
    local_sdxl: %{t2i: true, i2i: true, inpaint: true},
    google: %{t2i: true, i2i: false, inpaint: false},
    pollinations: %{t2i: true, i2i: false, inpaint: false}
  }

  def capabilities(provider \\ provider()), do: Map.fetch!(@capabilities, provider)

  @doc "Whether `provider` supports `:t2i`, `:i2i` or `:inpaint`."
  def supports?(provider \\ provider(), capability),
    do: Map.fetch!(capabilities(provider), capability)

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
      case i2i(prompt, image_url, opts) do
        {:error, reason} when image_url != nil and image_url != "" ->
          # An i2i frame that fails takes the whole rest of the song with it:
          # the canvas doesn't advance, so the next line retries the same call
          # against the same input and fails the same way. One stalled provider
          # request becomes a one-frame show.
          #
          # t2i needs no input image and no upload, so it is the one thing that
          # can still succeed here. The frame loses continuity with the previous
          # one — visible, but the alternative is a frozen stage.
          Logger.warning(
            "[image_gen] i2i failed (#{inspect(reason)}); rendering this frame as t2i so the song continues"
          )

          case t2i(prompt) do
            {:ok, url, frames} -> {:ok, url, frames}
            {:ok, url} -> {:ok, url, []}
            # Report the ORIGINAL failure: the fallback failing too means the
            # provider is down, and the first error is the one that explains it.
            {:error, _} -> {:error, reason}
          end

        result ->
          result
      end
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

  defp i2i(prompt, image_url, opts) do
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

      # Providers with no image-to-image endpoint. `render_mode/0` resolves
      # them to :t2i, so this is unreachable — kept as a belt-and-braces route
      # to the text-to-image path rather than a silent discard of the previous
      # frame, which is the bug the capability table exists to prevent.
      {p, _} when p in [:google, :pollinations] ->
        t2i(prompt)
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
  How each frame is rendered. Exactly two values, spelled the same everywhere:

    * `:i2i` (default) — the frame evolves the previous image.
    * `:t2i` — the frame is re-rendered from the full scene prompt.

  The codebase used to say `img2img`, `image2image`, `i2i` and `text2img`,
  `t2i` interchangeably across env vars, log lines and provenance records, so
  the same run described itself three different ways. `t2i`/`i2i` won because
  the benchmark task and the cost tables already used it. The older spellings
  are still accepted as input — someone's `.env` shouldn't break — but nothing
  emits them.

  The value returned here is the *effective* mode: asking a provider with no
  image-to-image endpoint for `i2i` resolves to `t2i`, because that is what it
  was always going to do anyway. Resolving it here rather than at the call site
  is what makes the rest of the pipeline coherent — story-mode deltas, style
  stamping and the provenance record all key off this answer, and they were
  each making the wrong choice while the raw env var said `i2i`. Use
  `requested_render_mode/0` for what the operator actually typed.
  """
  @spec render_mode() :: :t2i | :i2i
  def render_mode do
    case requested_render_mode() do
      :i2i -> if supports?(:i2i), do: :i2i, else: :t2i
      :t2i -> :t2i
    end
  end

  @doc "What `RENDER_MODE` asked for, before provider capabilities are applied."
  @spec requested_render_mode() :: :t2i | :i2i
  def requested_render_mode do
    case System.get_env("RENDER_MODE", "i2i") |> String.downcase() |> String.trim() do
      m when m in ~w(t2i text2img txt2img text2image t2img) -> :t2i
      _ -> :i2i
    end
  end

  @doc """
  Record which route/model actually served this frame.

  `provider/0` only reports what is *configured*, and one provider can serve a
  frame from very different models: Cloudflare's fast 6-step SDXL-Lightning for
  the opening text-to-image frame, then the 20-step SD-1.5 build for every frame
  after. Labelling both "cloudflare" made a 1.7s frame and a 6.9s frame look
  like the same thing.

  Every provider calls this *before* the request goes out, not after it
  succeeds, so a failure can still say what it was trying to do — an image
  error that names only `%Req.TransportError{reason: :timeout}` tells you
  nothing about which model, which route, or which endpoint gave up.

  `route` is `"t2i"` or `"i2i"`; see `render_mode/0` on why only those two
  spellings exist.
  """
  def note_route(route, model, steps) do
    Process.put(:image_route, %{
      provider: to_string(provider()),
      route: route,
      model: model,
      steps: steps
    })

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
