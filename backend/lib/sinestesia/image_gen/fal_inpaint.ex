defmodule Sinestesia.ImageGen.FalInpaint do
  @moduledoc """
  Flux dev inpainting via fal.ai.
  Used in compose story mode so new elements are painted into specific placement regions
  while keeping the rest of the canvas 100% untouched.
  """
  require Logger

  @url "https://fal.run/fal-ai/flux-general/inpainting"
  @model "fal-ai/flux-general/inpainting"
  @steps 10

  @spec generate(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, image_url, mask_url)
      when is_binary(prompt) and is_binary(image_url) and is_binary(mask_url) do
    # This is the route story mode actually takes on fal — NOT flux/dev
    # image-to-image. It went unlabelled for a while, and a failure here
    # reported itself as generic "fal i2i", which sent the investigation to
    # the wrong endpoint entirely.
    Sinestesia.ImageGen.note_route("i2i", @model, @steps)
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :fal_api_key) do
      nil ->
        {:error, :no_fal_key}

      key ->
        body = %{
          prompt: prompt,
          image_url: image_url,
          mask_url: mask_url,
          num_inference_steps: @steps,
          image_size: "landscape_16_9",
          enable_safety_checker: false
        }

        headers = [{"authorization", "Key " <> key}]

        case Req.post(@url,
               json: body,
               headers: headers,
               receive_timeout: timeout_ms(),
               retry: false
             ) do
          {:ok, %{status: 200, body: %{"images" => [%{"url" => url} | _]}}} ->
            {:ok, url}

          {:ok, resp} ->
            {:error, {:bad_status, resp.status, resp.body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # A frame that arrives 15s late has already missed its lyric — the audience
  # saw the line, waited, then got a picture of it. This budget is a deliberate
  # give-up point, not a safety net: past it, ImageGen falls back to t2i so the
  # song keeps moving. Tunable per show/venue.
  defp timeout_ms, do: String.to_integer(System.get_env("FAL_TIMEOUT_MS", "15000"))
end
