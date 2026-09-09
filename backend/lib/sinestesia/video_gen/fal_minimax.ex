defmodule Sinestesia.VideoGen.FalMinimax do
  @moduledoc """
  MiniMax H3 video generation via fal.ai's queue API — the clip engine
  behind motion mode (`mix sinestesia.video --motion`) and the single-clip
  probe (`mix sinestesia.motion`).

  Keyframe semantics: `from` is the clip's exact opening frame and `to`
  (optional) its exact final frame. Chaining clips that SHARE an anchor —
  clip N ends on the very image clip N+1 opens with — is what turns a
  sequence of scene stills into one continuous living video.

  This is PAID inference (per generated second) and must never sit on a live
  path: no retries that multiply spend, no silent fallback to a paid route.
  Callers own the cost math (`rates/1`) and the decision to submit.
  """
  require Logger

  @queue "https://queue.fal.run"

  # $/second, from the fal model pages (2026-08-29). h3-max launch promo
  # ("50% off, doubles September 1st") — callers should surface that a
  # post-promo run costs double the estimate.
  @models %{
    "h3-max" => %{
      endpoint: "minimax/h3-max/image-to-video",
      rates: %{"480P" => 0.025, "768P" => 0.04},
      promo: true
    },
    "h3" => %{
      endpoint: "minimax/h3/image-to-video",
      rates: %{"480P" => 0.05, "768P" => 0.06, "2K" => 0.13, "4K" => 0.16},
      promo: false
    }
  }

  @duration_range 5..15

  def models, do: Map.keys(@models)
  def model(name), do: Map.get(@models, name)
  def duration_range, do: @duration_range

  @doc "The API's closest billable duration for a scene window."
  def clamp_duration(seconds) when is_number(seconds) do
    seconds |> round() |> min(@duration_range.last) |> max(@duration_range.first)
  end

  @doc """
  Submit one clip to the queue. Returns `{:ok, request_url}` immediately —
  clips for a whole song are submitted together and awaited together, so the
  song renders in parallel on fal's side.

  Options: `:to` (final-frame path), `:duration` (integer seconds),
  `:resolution`, `:model`, `:base_url` (tests).
  """
  def submit(prompt, from, opts \\ []) do
    model_name = Keyword.get(opts, :model, "h3-max")

    %{endpoint: endpoint} =
      model(model_name) || raise ArgumentError, "unknown MiniMax model #{inspect(model_name)}"

    # `:base_url` (tests) and the :fal_queue_base app env (offline e2e runs
    # against a stub queue) both exist so this module's callers can be
    # exercised end to end without paid inference. Neither is an operator
    # setting; the real queue is not configurable.
    base =
      Keyword.get(
        opts,
        :base_url,
        Application.get_env(:sinestesia, :fal_queue_base, @queue)
      )

    body =
      %{
        prompt: prompt,
        image_url: data_uri(from),
        duration: Keyword.get(opts, :duration, @duration_range.first),
        resolution: Keyword.get(opts, :resolution, "768P"),
        prompt_expansion_mode: "balanced"
      }
      |> then(fn b ->
        case Keyword.get(opts, :to) do
          nil -> b
          to -> Map.put(b, :end_image_url, data_uri(to))
        end
      end)

    case Req.post("#{base}/#{endpoint}", json: body, headers: auth(), retry: false) do
      {:ok, %{status: 200, body: %{"request_id" => id}}} ->
        {:ok, "#{base}/#{endpoint}/requests/#{id}"}

      {:ok, resp} ->
        {:error, {:queue_rejected, resp.status, resp.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Poll a submitted request until it completes, then download the clip to
  `dest`. Generation time is minutes at worst; the deadline is a give-up
  point for a stuck queue, not a render budget.
  """
  def await(request_url, dest, opts \\ []) do
    deadline = now_ms() + Keyword.get(opts, :timeout_ms, 600_000)
    poll(request_url, dest, deadline)
  end

  defp poll(request_url, dest, deadline) do
    case Req.get(request_url <> "/status", headers: auth(), retry: false) do
      {:ok, %{status: 200, body: %{"status" => "COMPLETED"}}} ->
        fetch_result(request_url, dest)

      {:ok, %{status: 200, body: %{"status" => status}}} when status in ["IN_QUEUE", "IN_PROGRESS"] ->
        if now_ms() > deadline do
          {:error, {:stuck, status, request_url}}
        else
          Process.sleep(2_000)
          poll(request_url, dest, deadline)
        end

      {:ok, %{status: 200, body: body}} ->
        {:error, {:failed, body}}

      {:ok, resp} ->
        {:error, {:bad_status, resp.status, resp.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_result(request_url, dest) do
    with {:ok, %{status: 200, body: result}} <-
           Req.get(request_url, headers: auth(), retry: false),
         url when is_binary(url) <- get_in(result, ["video", "url"]) || {:error, {:no_video, result}},
         {:ok, %{status: 200, body: bin}} <-
           Req.get(url, decode_body: false, retry: false, receive_timeout: 120_000) do
      File.write!(dest, bin)
      {:ok, dest}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:result_fetch_failed, other}}
    end
  end

  defp auth do
    key =
      Application.fetch_env!(:sinestesia, :config)[:fal_api_key] ||
        raise "FAL_API_KEY is not set — MiniMax clips are paid fal.ai inference"

    [{"authorization", "Key " <> key}]
  end

  defp data_uri(path) do
    mime =
      case path |> Path.extname() |> String.downcase() do
        ".png" -> "image/png"
        ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
        ".webp" -> "image/webp"
        ext -> raise ArgumentError, "unsupported frame format #{ext} (jpg/png/webp)"
      end

    "data:#{mime};base64," <> Base.encode64(File.read!(path))
  end

  defp now_ms, do: System.system_time(:millisecond)
end
