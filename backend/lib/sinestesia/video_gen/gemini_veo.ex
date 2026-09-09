defmodule Sinestesia.VideoGen.GeminiVeo do
  @moduledoc """
  Veo 3.1 clips via the Gemini API — the same keyframe semantics as
  `Sinestesia.VideoGen.FalMinimax` (`from` is the exact opening frame,
  `to` the exact final frame), spoken through `predictLongRunning` +
  operation polling. Chosen as motion mode's default engine because the
  founder's Gemini credits make it the run-it-all-day option; MiniMax/fal
  stays for realtime experiments.

  Billed per generated second (2026-08-29, video+audio included):
  lite $0.05/720p · fast $0.10/720p · standard $0.40/720p. No free tier —
  "credits" are still spend, so the cost gates around this module stay.
  """
  require Logger

  @api_base "https://generativelanguage.googleapis.com/v1beta"

  @models %{
    "veo" => %{
      id: "veo-3.1-generate-preview",
      rates: %{"720p" => 0.40, "1080p" => 0.40, "4k" => 0.60}
    },
    "veo-fast" => %{
      id: "veo-3.1-fast-generate-preview",
      rates: %{"720p" => 0.10, "1080p" => 0.12, "4k" => 0.30}
    },
    "veo-lite" => %{
      id: "veo-3.1-lite-generate-preview",
      rates: %{"720p" => 0.05, "1080p" => 0.08}
    }
  }

  # The API's only billable clip lengths.
  @durations [4, 6, 8]

  def spec(name) do
    case Map.get(@models, name) do
      nil -> nil
      m -> %{rates: m.rates, promo: false, default_resolution: "720p"}
    end
  end

  @doc "Nearest billable duration to the scene window (ties go longer — retiming a slightly-long clip beats speeding one up)."
  def clamp_duration(seconds) when is_number(seconds) do
    Enum.min_by(@durations, fn d -> {abs(d - seconds), -d} end)
  end

  @doc """
  Start one clip. Returns `{:ok, operation_name}` — the awaitable ref.

  Options: `:to` (final-frame path), `:duration` (4|6|8), `:resolution`,
  `:model` (registry name), `:aspect_ratio` ("16:9"/"9:16"), `:base_url`.
  """
  def submit(prompt, from, opts \\ []) do
    name = Keyword.get(opts, :model, "veo-fast")

    %{id: model_id} =
      Map.get(@models, name) || raise ArgumentError, "unknown Veo model #{inspect(name)}"

    base = base_url(opts)

    instance =
      %{prompt: prompt, image: inline_data(from)}
      |> then(fn i ->
        case Keyword.get(opts, :to) do
          nil -> i
          to -> Map.put(i, :lastFrame, inline_data(to))
        end
      end)

    body = %{
      instances: [instance],
      parameters: %{
        aspectRatio: Keyword.get(opts, :aspect_ratio, "16:9"),
        durationSeconds: Keyword.get(opts, :duration, 8),
        resolution: Keyword.get(opts, :resolution, "720p")
      }
    }

    case Req.post("#{base}/models/#{model_id}:predictLongRunning",
           json: body,
           headers: auth(),
           retry: false,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"name" => op}}} -> {:ok, op}
      {:ok, resp} -> {:error, {:submit_rejected, resp.status, resp.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Poll the operation until done, then download the clip to `dest`. Veo
  renders in tens of seconds to minutes; the deadline is a stuck-queue
  give-up, not a render budget.
  """
  def await(operation_name, dest, opts \\ []) do
    deadline = now_ms() + Keyword.get(opts, :timeout_ms, 900_000)
    poll_ms = Keyword.get(opts, :poll_ms, 5_000)
    poll(operation_name, dest, base_url(opts), deadline, poll_ms)
  end

  defp poll(op, dest, base, deadline, poll_ms) do
    case Req.get("#{base}/#{op}", headers: auth(), retry: false) do
      {:ok, %{status: 200, body: %{"done" => true} = body}} ->
        fetch_result(body, dest)

      {:ok, %{status: 200, body: _pending}} ->
        if now_ms() > deadline do
          {:error, {:stuck, op}}
        else
          Process.sleep(poll_ms)
          poll(op, dest, base, deadline, poll_ms)
        end

      {:ok, resp} ->
        {:error, {:bad_status, resp.status, resp.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A done operation without a video is a REFUSAL, and Veo says why
  # (raiMediaFiltered*) — name it, per the Gemini-image lesson: an error
  # that only says "no video" is not an error report.
  defp fetch_result(body, dest) do
    response = Map.get(body, "response", %{})
    gvr = Map.get(response, "generateVideoResponse", %{})

    case get_in(gvr, ["generatedSamples", Access.at(0), "video", "uri"]) do
      uri when is_binary(uri) ->
        download(uri, dest)

      nil ->
        {:error,
         {:no_video,
          %{
            filtered_count: gvr["raiMediaFilteredCount"],
            filtered_reasons: gvr["raiMediaFilteredReasons"],
            error: body["error"]
          }}}
    end
  end

  defp download(uri, dest) do
    case Req.get(uri, headers: auth(), decode_body: false, retry: false, receive_timeout: 300_000) do
      {:ok, %{status: 200, body: bin}} ->
        File.write!(dest, bin)
        {:ok, dest}

      other ->
        {:error, {:download_failed, other, uri}}
    end
  end

  # `:base_url` (tests) and the :veo_api_base app env (offline e2e stubs)
  # exist so callers can be exercised end to end without paid inference.
  # Neither is an operator setting.
  defp base_url(opts) do
    Keyword.get(opts, :base_url, Application.get_env(:sinestesia, :veo_api_base, @api_base))
  end

  defp auth do
    key =
      Application.fetch_env!(:sinestesia, :config)[:google_api_key] ||
        raise "GOOGLE_API_KEY is not set — Veo clips are paid Gemini inference"

    [{"x-goog-api-key", key}]
  end

  defp inline_data(path) do
    mime =
      case path |> Path.extname() |> String.downcase() do
        ".png" -> "image/png"
        ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
        ".webp" -> "image/webp"
        ext -> raise ArgumentError, "unsupported frame format #{ext} (jpg/png/webp)"
      end

    %{inlineData: %{mimeType: mime, data: Base.encode64(File.read!(path))}}
  end

  defp now_ms, do: System.system_time(:millisecond)
end
