defmodule Mix.Tasks.Sinestesia.Motion do
  @shortdoc "Prototype: a scene transition as REAL generated video (fal MiniMax H3)"
  @moduledoc """
  Prototype for replacing a crossfade with generated MOTION: give it the two
  frames of a scene boundary and the scene's prompt, get back a video clip
  that starts exactly on frame A and ends exactly on frame B (MiniMax H3's
  first/last-frame keyframe mode via fal.ai).

      mix sinestesia.motion --from frame_03.jpg --to frame_04.jpg \\
        --prompt "a city silhouette with glowing stars. watercolor night" \\
        --out transition.mp4

  What this is probing: today `mix sinestesia.video` fills the gap between
  reveals with latent morphs or synthetic blends — interpolation, not motion.
  A keyframed video clip would make the leaves actually sway and the river
  actually flow between the same two anchor images. If the quality justifies
  the cost, the follow-up is a `--motion` mode in `mix sinestesia.video`
  generating one clip per scene window (retimed to fit each slot).

  This is PAID inference and it is deliberately kept off every live path:
  one explicit clip per invocation, cost printed before submitting. Rates at
  768P (2026-08-29): h3-max $0.04/s (launch promo — doubles ~Sep 1), h3
  $0.06/s. A whole 3-minute song as continuous 768P video ≈ $7-11 at promo
  rates — viable for an application-kit video, not for every render.

  ## Options

      --from PATH        opening frame (required)
      --to PATH          final frame (optional — omit for plain i2v drift)
      --prompt TEXT      scene prompt (required; the Director's line + style)
      --model NAME       h3-max (default) | h3
      --duration S       5-15 seconds (default 5, the minimum billable clip)
      --resolution R     480P | 768P (default; h3 also takes 2K | 4K)
      --out PATH         output mp4 (default: motion-<timestamp>.mp4)

  Needs FAL_API_KEY (same key ImageGen's fal providers use).
  """
  use Mix.Task
  require Logger

  @queue "https://queue.fal.run"

  # $/second, from the fal model pages (2026-08-29). h3-max is a launch promo
  # ("50% off, doubles September 1st") — the estimate below prints both so a
  # post-promo run isn't a surprise on the invoice.
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

  @impl true
  def run(args) do
    opts = parse_args(args)

    from = require_file(opts[:from] || Mix.raise("--from is required (the opening frame)"))
    to = if opts[:to], do: require_file(opts[:to])
    prompt = opts[:prompt] || Mix.raise("--prompt is required (the scene's Director prompt)")

    model_name = opts[:model] || "h3-max"

    model =
      Map.get(@models, model_name) ||
        Mix.raise("unknown --model #{model_name} (h3-max | h3)")

    duration = opts[:duration] || 5

    duration in 5..15 ||
      Mix.raise("--duration must be 5-15 seconds (the API's range), got #{duration}")

    resolution = opts[:resolution] || "768P"

    rate =
      Map.get(model.rates, resolution) ||
        Mix.raise("#{model_name} has no #{resolution} (options: #{Enum.join(Map.keys(model.rates), " | ")})")

    cost = Float.round(duration * rate, 3)

    promo_note =
      if model.promo, do: " (launch promo — ~$#{Float.round(cost * 2, 3)} after Sep 1)", else: ""

    Mix.shell().info(
      "── #{model_name} #{resolution} #{duration}s → ~$#{cost}#{promo_note} ──"
    )

    # Boot for the same reasons sinestesia.video does: runtime.exs is what
    # loads .env (FAL_API_KEY lives there), and Req needs Finch running.
    System.put_env("PORT", System.get_env("REPLAY_PORT", "4999"))
    Mix.Task.run("app.start")

    key =
      Application.fetch_env!(:sinestesia, :config)[:fal_api_key] ||
        Mix.raise("FAL_API_KEY is not set — this is paid fal.ai inference and cannot run without it")

    headers = [{"authorization", "Key " <> key}]

    body =
      %{
        prompt: prompt,
        image_url: data_uri(from),
        duration: duration,
        resolution: resolution,
        prompt_expansion_mode: "balanced"
      }
      |> then(fn b -> if to, do: Map.put(b, :end_image_url, data_uri(to)), else: b end)

    Mix.shell().info("[motion] submitting to #{model.endpoint}")

    request_url =
      case Req.post("#{@queue}/#{model.endpoint}", json: body, headers: headers, retry: false) do
        {:ok, %{status: 200, body: %{"request_id" => id}}} ->
          "#{@queue}/#{model.endpoint}/requests/#{id}"

        {:ok, resp} ->
          Mix.raise("fal queue rejected the request (HTTP #{resp.status}): #{inspect(resp.body)}")

        {:error, reason} ->
          Mix.raise("could not reach fal: #{inspect(reason)}")
      end

    result = await(request_url, headers, _deadline_ms = now_ms() + 300_000)

    video_url =
      get_in(result, ["video", "url"]) ||
        Mix.raise("fal reported COMPLETED but returned no video URL: #{inspect(result)}")

    if expanded = result["expanded_prompt"],
      do: Mix.shell().info("[motion] expanded prompt: #{expanded}")

    out = opts[:out] || "motion-#{System.system_time(:second)}.mp4"

    case Req.get(video_url, decode_body: false, retry: false, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: bin}} ->
        File.write!(out, bin)
        Mix.shell().info("\n── done (~$#{cost}) ──\n#{Path.expand(out)}")

      other ->
        Mix.raise("""
        the clip rendered but downloading it failed: #{inspect(other)}
        fetch it manually before the CDN link expires: #{video_url}
        """)
    end
  end

  defp await(request_url, headers, deadline_ms) do
    case Req.get(request_url <> "/status", headers: headers, retry: false) do
      {:ok, %{status: 200, body: %{"status" => "COMPLETED"}}} ->
        case Req.get(request_url, headers: headers, retry: false) do
          {:ok, %{status: 200, body: result}} -> result
          other -> Mix.raise("fetching the finished result failed: #{inspect(other)}")
        end

      {:ok, %{status: 200, body: %{"status" => status} = st}} ->
        if now_ms() > deadline_ms do
          Mix.raise("gave up after 5 minutes still #{status} — check fal.ai/dashboard/requests")
        end

        if pos = st["queue_position"],
          do: Mix.shell().info("[motion] #{status} (queue position #{pos})"),
          else: Mix.shell().info("[motion] #{status}")

        Process.sleep(2_000)
        await(request_url, headers, deadline_ms)

      {:ok, resp} ->
        Mix.raise("status poll failed (HTTP #{resp.status}): #{inspect(resp.body)}")

      {:error, reason} ->
        Mix.raise("status poll failed: #{inspect(reason)}")
    end
  end

  defp require_file(path) do
    path = Path.expand(path)
    File.exists?(path) || Mix.raise("file not found: #{path}")
    path
  end

  defp data_uri(path) do
    mime =
      case path |> Path.extname() |> String.downcase() do
        ".png" -> "image/png"
        ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
        ".webp" -> "image/webp"
        ext -> Mix.raise("unsupported frame format #{ext} (jpg/png/webp)")
      end

    "data:#{mime};base64," <> Base.encode64(File.read!(path))
  end

  defp parse_args(args) do
    case OptionParser.parse(args,
           strict: [
             from: :string,
             to: :string,
             prompt: :string,
             model: :string,
             duration: :integer,
             resolution: :string,
             out: :string
           ]
         ) do
      {opts, [], []} ->
        opts

      _ ->
        Mix.raise(
          "usage: mix sinestesia.motion --from A.jpg [--to B.jpg] --prompt TEXT " <>
            "[--model h3-max|h3] [--duration 5-15] [--resolution 480P|768P] [--out PATH]"
        )
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
