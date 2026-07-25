defmodule Sinestesia.ImageGen.Fal do
  @moduledoc "Flux Schnell via fal.ai. Fastest open option (~400-600ms)."
  require Logger

  @url "https://fal.run/fal-ai/flux/schnell"
  @model "fal-ai/flux/schnell"
  @steps 4

  @spec generate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt) do
    Sinestesia.ImageGen.note_route("t2i", @model, @steps)
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :fal_api_key) do
      nil ->
        {:error, :no_fal_key}

      key ->
        body = %{
          prompt: prompt,
          image_size: "landscape_16_9",
          num_inference_steps: @steps,
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
