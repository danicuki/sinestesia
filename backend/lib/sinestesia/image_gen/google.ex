defmodule Sinestesia.ImageGen.Google do
  @moduledoc """
  Google Imagen 4 Fast via Gemini API.

  Returns a `data:image/png;base64,...` URL — Three.js TextureLoader handles
  that the same as an HTTPS URL.
  """
  require Logger

  @model "imagen-4.0-fast-generate-001"

  @spec generate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :google_api_key) do
      nil ->
        {:error, :no_google_key}

      key ->
        url =
          "https://generativelanguage.googleapis.com/v1beta/models/#{@model}:predict?key=#{key}"

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
