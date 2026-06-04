defmodule Sinestesia.ImageGen.Fal do
  @moduledoc "Flux Schnell via fal.ai. Fastest open option (~400-600ms)."
  require Logger

  @url "https://fal.run/fal-ai/flux/schnell"

  @spec generate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :fal_api_key) do
      nil ->
        {:error, :no_fal_key}

      key ->
        body = %{
          prompt: prompt,
          image_size: "landscape_16_9",
          num_inference_steps: 4,
          enable_safety_checker: false
        }

        headers = [{"authorization", "Key " <> key}]

        case Req.post(@url,
               json: body,
               headers: headers,
               receive_timeout: 8_000,
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
