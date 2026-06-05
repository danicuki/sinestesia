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
  @strength 0.90
  @steps 10

  @spec generate(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, image_url) when is_binary(prompt) and is_binary(image_url) do
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
               receive_timeout: 15_000,
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
end
