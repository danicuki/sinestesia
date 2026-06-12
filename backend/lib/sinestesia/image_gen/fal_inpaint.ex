defmodule Sinestesia.ImageGen.FalInpaint do
  @moduledoc """
  Flux dev inpainting via fal.ai.
  Used in compose story mode so new elements are painted into specific placement regions
  while keeping the rest of the canvas 100% untouched.
  """
  require Logger

  @url "https://fal.run/fal-ai/flux-general/inpainting"
  @steps 10

  @spec generate(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, image_url, mask_url) when is_binary(prompt) and is_binary(image_url) and is_binary(mask_url) do
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
