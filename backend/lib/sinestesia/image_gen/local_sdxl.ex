defmodule Sinestesia.ImageGen.LocalSdxl do
  @moduledoc """
  Image generator using a local SDXL Turbo img2img sidecar (see `local-sdxl/`).

  Drop-in replacement for `Sinestesia.ImageGen.FalImg2Img` — same request
  shape (prompt + image_url + strength), same response (`{:ok, url}` |
  `{:error, term}`). Returned URL points at `http://localhost:8003/img/<id>.png`
  which the browser fetches directly.

  Faster than fal (~700 ms vs ~1.5 s warm) and free, in exchange for needing
  the Python sidecar running.
  """
  require Logger

  defp base_url, do: System.get_env("LOCAL_SDXL_URL", "http://127.0.0.1:8003")
  # 0.78 strength + 3 steps gives ~2 real denoising steps with enough injected
  # noise that each frame visibly evolves (fal's Flux ran at 0.8). Lower this
  # toward 0.5 if frames change TOO much and lose continuity.
  defp strength, do: System.get_env("LOCAL_SDXL_STRENGTH", "0.78") |> String.to_float()
  defp steps, do: System.get_env("LOCAL_SDXL_STEPS", "3") |> String.to_integer()

  @spec generate(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, image_url) when is_binary(prompt) and is_binary(image_url) do
    body = %{
      prompt: prompt,
      image_url: image_url,
      strength: strength(),
      num_inference_steps: steps(),
      image_size: "landscape_16_9"
    }

    case Req.post(base_url() <> "/generate",
           json: body,
           receive_timeout: 30_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"images" => [%{"url" => url} | _]}}} ->
        {:ok, url}

      {:ok, %{status: status, body: body}} ->
        {:error, {:bad_status, status, body}}

      {:error, reason} ->
        Logger.warning("[local_sdxl] request failed: #{inspect(reason)} (is the sidecar running on #{base_url()}?)")
        {:error, reason}
    end
  end
end
