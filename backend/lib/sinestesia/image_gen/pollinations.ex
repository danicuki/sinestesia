defmodule Sinestesia.ImageGen.Pollinations do
  @moduledoc """
  Pollinations.ai — free, no auth, Flux model.

  The URL itself returns the rendered image when fetched. We construct it,
  optionally pre-fetch to validate (and to roughly time generation since
  Pollinations renders on demand), then return the URL.
  """
  require Logger

  @base "https://image.pollinations.ai/prompt/"

  @spec generate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt) do
    seed = :rand.uniform(2_147_483_647)

    qs =
      URI.encode_query(%{
        model: "flux",
        width: 1024,
        height: 576,
        nologo: "true",
        seed: seed
      })

    url = @base <> URI.encode(prompt, &URI.char_unreserved?/1) <> "?" <> qs

    # Pre-fetch HEAD to nudge Pollinations to render and to verify availability.
    # If this fails, we still return the URL — the browser will retry.
    case Req.head(url, receive_timeout: 12_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, url}

      {:ok, %{status: status}} ->
        Logger.warning("[pollinations] head returned #{status}; returning URL anyway")
        {:ok, url}

      {:error, reason} ->
        Logger.warning("[pollinations] head failed: #{inspect(reason)}; returning URL anyway")
        {:ok, url}
    end
  end
end
