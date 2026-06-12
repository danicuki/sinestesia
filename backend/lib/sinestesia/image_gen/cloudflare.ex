defmodule Sinestesia.ImageGen.Cloudflare do
  @moduledoc """
  Cloudflare Workers AI image generation — covered by startup credits, so
  experiments cost nothing out of pocket (confirm in the dashboard that
  Workers AI "neurons" draw from the credit balance).

  Two models, picked automatically:

    * no previous image  → FLUX.1 schnell (text-to-image, bootstrap frame)
    * previous image     → SD 1.5 img2img (CLOUDFLARE_IMG2IMG_MODEL) — unlike
      the local SDXL Turbo sidecar this runs REAL classifier-free guidance
      (~20 steps, guidance 7.5), so the prompt actually steers content and
      style.

  Returns `data:image/...;base64,...` URLs. The frontend renders those like
  any HTTPS URL, and this module decodes them back when chaining img2img.

  Env: CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN (Workers AI permission),
  optional CLOUDFLARE_STRENGTH / CLOUDFLARE_STEPS / CLOUDFLARE_GUIDANCE.
  """
  require Logger

  @t2i_model "@cf/black-forest-labs/flux-1-schnell"

  # NOT @cf/stabilityai/stable-diffusion-xl-base-1.0: despite the docs schema
  # listing an `image` input, the deployed build rejects it ("input tensor
  # `image` is not present in the model"). The runwayml model is the only
  # purpose-built img2img on Workers AI (SD 1.5 — weaker than SDXL but with
  # real CFG, which is the hypothesis being tested).
  defp img2img_model do
    System.get_env("CLOUDFLARE_IMG2IMG_MODEL", "@cf/runwayml/stable-diffusion-v1-5-img2img")
  end

  @spec text2img(String.t()) :: {:ok, String.t()} | {:error, term()}
  def text2img(prompt) do
    # Flux schnell answers JSON with a base64 JPEG.
    case post(@t2i_model, %{prompt: prompt, steps: 6}) do
      {:ok, %{"result" => %{"image" => b64}}} ->
        {:ok, "data:image/jpeg;base64," <> b64}

      {:ok, other} ->
        {:error, {:unexpected_body, other}}

      error ->
        error
    end
  end

  @spec img2img(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def img2img(prompt, image_url) do
    with {:ok, b64} <- input_b64(image_url) do
      body = %{
        prompt: prompt,
        image_b64: b64,
        num_steps: steps(),
        strength: strength(),
        guidance: guidance()
      }

      # The model answers the raw image binary.
      case post(img2img_model(), body) do
        {:ok, bin} when is_binary(bin) ->
          {:ok, "data:image/png;base64," <> Base.encode64(bin)}

        {:ok, other} ->
          {:error, {:unexpected_body, other}}

        error ->
          error
      end
    end
  end

  defp post(model, body) do
    with {:ok, account, token} <- credentials() do
      url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/run/#{model}"

      case Req.post(url,
             json: body,
             auth: {:bearer, token},
             receive_timeout: 60_000,
             retry: false
           ) do
        {:ok, %{status: 200, body: resp}} ->
          {:ok, resp}

        {:ok, %{status: status, body: resp}} ->
          Logger.warning("[cloudflare] HTTP #{status}: #{inspect(resp, limit: 5)}")
          {:error, {:bad_status, status, resp}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Previous frame arrives either as our own data URL (normal chaining) or
  # as an external HTTPS URL (e.g. a fal bootstrap) that we download.
  defp input_b64("data:image/" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [_meta, b64] -> {:ok, b64}
      _ -> {:error, :bad_data_url}
    end
  end

  defp input_b64("http" <> _ = url) do
    case Req.get(url, receive_timeout: 15_000, retry: false, decode_body: false) do
      {:ok, %{status: 200, body: bin}} -> {:ok, Base.encode64(bin)}
      {:ok, %{status: status}} -> {:error, {:input_fetch, status}}
      {:error, reason} -> {:error, {:input_fetch, reason}}
    end
  end

  defp input_b64(other), do: {:error, {:bad_input_url, other}}

  defp credentials do
    account = System.get_env("CLOUDFLARE_ACCOUNT_ID")
    token = System.get_env("CLOUDFLARE_API_TOKEN")

    if account in [nil, ""] or token in [nil, ""] do
      {:error, :no_cloudflare_credentials}
    else
      {:ok, account, token}
    end
  end

  # SDXL base obeys prompts (real CFG), so a slightly lower strength than the
  # local Turbo default keeps more continuity while still evolving the frame.
  defp strength do
    case Float.parse(System.get_env("CLOUDFLARE_STRENGTH", "0.7")) do
      {s, _} when s > 0 and s <= 1 -> s
      _ -> 0.7
    end
  end

  defp steps do
    case Integer.parse(System.get_env("CLOUDFLARE_STEPS", "20")) do
      {n, _} when n in 1..20 -> n
      _ -> 20
    end
  end

  defp guidance do
    case Float.parse(System.get_env("CLOUDFLARE_GUIDANCE", "7.5")) do
      {g, _} when g > 0 -> g
      _ -> 7.5
    end
  end
end
