defmodule Mix.Tasks.Sinestesia.Motion do
  @shortdoc "Probe: one scene transition as REAL generated video (fal MiniMax H3)"
  @moduledoc """
  Single-clip probe for motion mode: give it the two frames of a scene
  boundary and a direction, get back a clip that starts exactly on frame A
  and ends exactly on frame B (MiniMax H3 first/last-frame keyframes via
  fal.ai). Use it to judge quality for ~$0.20 before spending on a whole
  song with `mix sinestesia.video --motion`.

      mix sinestesia.motion --from frame_03.jpg --to frame_04.jpg \\
        --prompt "the leaves sway as the camera drifts toward the window" \\
        --out transition.mp4

  This is PAID inference, deliberately off every live path: one explicit
  clip per invocation, cost printed before submitting.

  ## Options

      --from PATH        opening frame (required)
      --to PATH          final frame (optional — omit for plain i2v drift)
      --prompt TEXT      motion direction (required)
      --model NAME       h3-max (default) | h3
      --duration S       5-15 seconds (default 5, the minimum billable clip)
      --resolution R     480P | 768P (default; h3 also takes 2K | 4K)
      --out PATH         output mp4 (default: motion-<timestamp>.mp4)

  Needs FAL_API_KEY (same key ImageGen's fal providers use).
  """
  use Mix.Task

  alias Sinestesia.VideoGen.FalMinimax

  @impl true
  def run(args) do
    opts = parse_args(args)

    from = require_file(opts[:from] || Mix.raise("--from is required (the opening frame)"))
    to = if opts[:to], do: require_file(opts[:to])
    prompt = opts[:prompt] || Mix.raise("--prompt is required (the motion direction)")

    model_name = opts[:model] || "h3-max"

    model =
      FalMinimax.model(model_name) ||
        Mix.raise("unknown --model #{model_name} (#{Enum.join(FalMinimax.models(), " | ")})")

    duration = opts[:duration] || FalMinimax.duration_range().first

    duration in FalMinimax.duration_range() ||
      Mix.raise("--duration must be #{inspect(FalMinimax.duration_range())} seconds, got #{duration}")

    resolution = opts[:resolution] || "768P"

    rate =
      Map.get(model.rates, resolution) ||
        Mix.raise("#{model_name} has no #{resolution} (options: #{Enum.join(Map.keys(model.rates), " | ")})")

    cost = Float.round(duration * rate, 3)

    promo_note =
      if model.promo, do: " (launch promo — roughly double after it ends)", else: ""

    Mix.shell().info("── #{model_name} #{resolution} #{duration}s → ~$#{cost}#{promo_note} ──")

    # Boot for the same reasons sinestesia.video does: runtime.exs is what
    # loads .env (FAL_API_KEY lives there), and Req needs Finch running.
    System.put_env("PORT", System.get_env("REPLAY_PORT", "4999"))
    Mix.Task.run("app.start")

    Application.fetch_env!(:sinestesia, :config)[:fal_api_key] ||
      Mix.raise("FAL_API_KEY is not set — this is paid fal.ai inference and cannot run without it")

    out = opts[:out] || "motion-#{System.system_time(:second)}.mp4"

    Mix.shell().info("[motion] submitting to #{model.endpoint}")

    with {:ok, request_url} <-
           FalMinimax.submit(prompt, from,
             to: to,
             duration: duration,
             resolution: resolution,
             model: model_name
           ),
         {:ok, path} <- FalMinimax.await(request_url, out) do
      Mix.shell().info("\n── done (~$#{cost}) ──\n#{Path.expand(path)}")
    else
      {:error, reason} -> Mix.raise("clip generation failed: #{inspect(reason)}")
    end
  end

  defp require_file(path) do
    path = Path.expand(path)
    File.exists?(path) || Mix.raise("file not found: #{path}")
    path
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
end
