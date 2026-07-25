defmodule Sinestesia.ImageGen.Google do
  @moduledoc """
  Google Imagen 4 Fast via Gemini API.

  Returns a `data:image/png;base64,...` URL — Three.js TextureLoader handles
  that the same as an HTTPS URL.
  """
  require Logger

  @default_model "imagen-4.0-fast-generate-001"

  @doc """
  Generate an image from `prompt`.

  Pass `model:` to override the default Imagen model (e.g. to benchmark the
  early-access "instant ramen" model). Falls back to the `GOOGLE_IMAGE_MODEL`
  env var, then to `#{@default_model}`.
  """
  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, opts \\ []) do
    cfg = Application.fetch_env!(:sinestesia, :config)
    model = opts[:model] || System.get_env("GOOGLE_IMAGE_MODEL") || @default_model
    # Imagen has no image-to-image endpoint here: every frame is text-to-image,
    # whatever RENDER_MODE says.
    Sinestesia.ImageGen.note_route("t2i", model, nil)

    case Keyword.get(cfg, :google_api_key) do
      nil ->
        {:error, :no_google_key}

      key ->
        url =
          "https://generativelanguage.googleapis.com/v1beta/models/#{model}:predict?key=#{key}"

        body = %{
          instances: [%{prompt: prompt}],
          parameters: %{
            sampleCount: 1,
            aspectRatio: "16:9",
            personGeneration: "ALLOW_ADULT"
          }
        }

        case Req.post(url, json: body, receive_timeout: 8_000, retry: false) do
          {:ok, %{status: 200, body: %{"predictions" => [%{"bytesBase64Encoded" => b64} | _]}}} ->
            {:ok, "data:image/png;base64," <> b64}

          {:ok, resp} ->
            {:error, {:bad_status, resp.status, resp.body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
