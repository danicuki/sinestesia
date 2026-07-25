defmodule Sinestesia.ImageGen.FalImg2Img do
  @moduledoc """
  Flux dev image-to-image via fal.ai. Used in story mode so each new image
  builds on top of the previous one — elements accumulate instead of resetting.

  Slower than schnell (~1.2-1.8s vs ~500ms) but the visual continuity is the
  whole point of story mode.

  `strength`: 0.0 → keep input image unchanged. 1.0 → ignore input, pure text-to-image.
  ~0.55 is the sweet spot for accumulation: lets new elements appear while
  preserving the existing drawing's composition and style.
  """
  require Logger

  @url "https://fal.run/fal-ai/flux/dev/image-to-image"
  @model "fal-ai/flux/dev/image-to-image"
  @strength 0.8
  @steps 10

  @spec generate(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, image_url) when is_binary(prompt) and is_binary(image_url) do
    Sinestesia.ImageGen.note_route("i2i", @model, @steps)
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :fal_api_key) do
      nil ->
        {:error, :no_fal_key}

      key ->
        body = %{
          prompt: prompt,
          image_url: image_url,
          strength: @strength,
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
