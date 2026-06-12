defmodule Sinestesia.ImageGen.LocalSdxl do
  @moduledoc """
  Image generator using a local SDXL Turbo img2img sidecar (see `local-sdxl/`).

  Drop-in replacement for `Sinestesia.ImageGen.FalImg2Img` — same request
  shape (prompt + image_url + strength). Returned URL points at
  `http://localhost:8003/img/<id>.png` which the browser fetches directly.

  Unlike the other providers it returns `{:ok, url, frames}`: `frames` is the
  latent-space morph sequence (previous image → new image, ending on the final
  URL) that the frontend plays as a continuous generative morph. Empty when
  the sidecar runs with `MORPH_FRAMES=0`.

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

  @spec generate(String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def generate(prompt, image_url, opts \\ []) when is_binary(prompt) do
    body = %{
      prompt: prompt,
      image_url: image_url,
      # Per-request overrides (compose mode sends gentler values for
      # atmospheric passes); env defaults otherwise.
      strength: Keyword.get(opts, :strength, strength()),
      num_inference_steps: Keyword.get(opts, :steps, steps()),
      image_size: "landscape_16_9"
    }

    # Operator camera (zoom/pan, -1..1) — the sidecar warps the previous
    # frame's latents by this before denoising. Omitted when neutral.
    body =
      case Keyword.get(opts, :camera) do
        %{} = cam -> Map.put(body, :camera, cam)
        _ -> body
      end

    # Compose mode: inpaint the element into the placement region only.
    body =
      case Keyword.get(opts, :element) do
        el when is_binary(el) and el != "" ->
          body
          |> Map.put(:element, el)
          |> Map.put(:placement, Keyword.get(opts, :placement, "center"))

        _ ->
          body
      end

    # Periodic style recovery: the sidecar chains a gentle whole-canvas
    # img2img with this text after the main op (see STYLE_PASS_STRENGTH).
    body =
      case Keyword.get(opts, :style_pass) do
        sp when is_binary(sp) and sp != "" -> Map.put(body, :style_pass, sp)
        _ -> body
      end

    case Req.post(base_url() <> "/generate",
           json: body,
           receive_timeout: 30_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"images" => [%{"url" => url} | _]} = body}} ->
        frames =
          case Map.get(body, "frames") do
            urls when is_list(urls) -> Enum.filter(urls, &is_binary/1)
            _ -> []
          end

        {:ok, url, frames}

      {:ok, %{status: status, body: body}} ->
        {:error, {:bad_status, status, body}}

      {:error, reason} ->
        Logger.warning("[local_sdxl] request failed: #{inspect(reason)} (is the sidecar running on #{base_url()}?)")
        {:error, reason}
    end
  end
end
