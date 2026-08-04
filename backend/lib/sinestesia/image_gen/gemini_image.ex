defmodule Sinestesia.ImageGen.GeminiImage do
  @moduledoc """
  Google image generation for `IMAGE_PROVIDER=google`: Gemini native image
  models via the `:generateContent` endpoint.

  This replaced the Imagen client (`:predict` endpoint) — Imagen 4 is
  deprecated (shutting down 2026-08-17) and had no image-to-image. Gemini image
  models take a multimodal `contents` payload and return image bytes inline,
  which means the same call does both:

    * text-to-image  — `generate(prompt)`
    * image-to-image — `generate(prompt, image_url: data_or_http_url)` (the seed
      is sent as an inline image part alongside the prompt)

  Returns `data:image/...;base64,...`. Model id comes from `opts[:model]`, then
  the `GOOGLE_IMAGE_MODEL` env var, then the default. A leading `models/`
  prefix is stripped. The model must be a Gemini `*-image` model — pointing
  this at an Imagen id fails with a 404, since Imagen only ever lived on
  `:predict`.
  """
  require Logger

  @default_model "gemini-3.1-flash-lite-image"

  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, opts \\ []) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    model =
      (opts[:model] || System.get_env("GOOGLE_IMAGE_MODEL") || @default_model)
      |> normalize_model()

    route = if opts[:image_url] in [nil, ""], do: "t2i", else: "i2i"
    Sinestesia.ImageGen.note_route(route, model, nil)

    case Keyword.get(cfg, :google_api_key) do
      nil ->
        {:error, :no_google_key}

      key ->
        with {:ok, parts} <- build_parts(prompt, opts[:image_url]) do
          url =
            "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

          body = %{
            contents: [%{parts: parts}],
            generationConfig: %{responseModalities: ["IMAGE"]}
          }

          case Req.post(url, json: body, receive_timeout: 30_000, retry: false) do
            {:ok, %{status: 200, body: resp}} -> extract_image(resp)
            {:ok, resp} -> {:error, {:bad_status, resp.status, resp.body}}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp normalize_model(model), do: String.replace_prefix(model, "models/", "")

  # text-only → one text part. i2i → text part + inline seed image part.
  defp build_parts(prompt, nil), do: {:ok, [%{text: prompt}]}

  defp build_parts(prompt, image_url) do
    with {:ok, mime, b64} <- inline_image(image_url) do
      {:ok, [%{text: prompt}, %{inlineData: %{mimeType: mime, data: b64}}]}
    end
  end

  defp inline_image("data:image/" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [meta, b64] ->
        mime = "image/" <> (meta |> String.split(";") |> List.first())
        {:ok, mime, b64}

      _ ->
        {:error, :bad_data_url}
    end
  end

  defp inline_image("http" <> _ = url) do
    case Req.get(url, receive_timeout: 15_000, retry: false, decode_body: false) do
      {:ok, %{status: 200, body: bin}} ->
        mime = if String.contains?(url, ".png"), do: "image/png", else: "image/jpeg"
        {:ok, mime, Base.encode64(bin)}

      {:ok, %{status: status}} ->
        {:error, {:input_fetch, status}}

      {:error, reason} ->
        {:error, {:input_fetch, reason}}
    end
  end

  defp inline_image(other), do: {:error, {:bad_input_url, other}}

  defp extract_image(%{"candidates" => candidates} = body) do
    candidate = List.first(candidates, %{})
    parts = get_in(candidate, ["content", "parts"]) || []

    case Enum.find(parts, &match?(%{"inlineData" => %{"data" => _}}, &1)) do
      %{"inlineData" => %{"data" => b64} = data} ->
        mime = Map.get(data, "mimeType", "image/png")
        {:ok, "data:#{mime};base64," <> b64}

      _ ->
        # A 200 with no image is a REFUSAL, and the reason is never in the
        # parts (they come back empty) — it's in the candidate's
        # finishReason (IMAGE_SAFETY, PROHIBITED_CONTENT, RECITATION —
        # trademarked characters land here: "spider-man" fails where
        # "spider-suit hero" passes) and in promptFeedback. Surface both:
        # someone at a sound desk needs to know WHICH word poisoned the
        # prompt, not that a list was empty.
        {:error,
         {:no_image_in_response,
          %{
            finish_reason: Map.get(candidate, "finishReason"),
            block_reason: get_in(body, ["promptFeedback", "blockReason"]),
            refusal_text:
              parts |> Enum.find_value(&Map.get(&1, "text")) |> then(&(&1 && String.slice(&1, 0, 200)))
          }}}
    end
  end

  defp extract_image(other), do: {:error, {:unexpected_body, other}}
end
