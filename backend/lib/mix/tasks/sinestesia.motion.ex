defmodule Mix.Tasks.Sinestesia.Motion do
  @shortdoc "Probe: one scene transition as REAL generated video (Veo or MiniMax)"
  @moduledoc """
  Single-clip probe for motion mode: give it the two frames of a scene
  boundary and a direction, get back a clip that starts exactly on frame A
  and ends exactly on frame B (first/last-frame keyframes). Use it to judge
  an engine's quality for cents before spending on a whole song with
  `mix sinestesia.video --motion`.

      mix sinestesia.motion --from frame_03.jpg --to frame_04.jpg \\
        --prompt "the leaves sway as the camera drifts toward the window" \\
        --out transition.mp4

  Engines (`Sinestesia.VideoGen`): veo-fast (default), veo-lite, veo — Veo
  3.1 through the Gemini API and its credits (GOOGLE_API_KEY) — and
  h3-max, h3 — MiniMax through fal (FAL_API_KEY). This is PAID inference,
  deliberately off every live path: one explicit clip per invocation, cost
  printed before submitting.

  ## Options

      --from PATH        opening frame (required)
      --to PATH          final frame (optional — omit for plain i2v drift)
      --prompt TEXT      motion direction (required)
      --model NAME       veo-fast (default) | veo-lite | veo | h3-max | h3
      --duration S       veo: 4|6|8 · fal: 5-15 (default: the engine's minimum)
      --resolution R     veo: 720p (default) | 1080p | 4k · fal: 480P | 768P
      --out PATH         output mp4 (default: motion-<timestamp>.mp4)
  """
  use Mix.Task

  @impl true
  def run(args) do
    opts = parse_args(args)

    from = require_file(opts[:from] || Mix.raise("--from is required (the opening frame)"))
    to = if opts[:to], do: require_file(opts[:to])
    prompt = opts[:prompt] || Mix.raise("--prompt is required (the motion direction)")

    model_name = opts[:model] || "veo-fast"

    engine =
      Sinestesia.VideoGen.engine(model_name) ||
        Mix.raise("unknown --model #{model_name} (#{Enum.join(Sinestesia.VideoGen.names(), " | ")})")

    spec = engine.spec(model_name)

    duration = opts[:duration] || engine.clamp_duration(0)

    engine.clamp_duration(duration) == duration ||
      Mix.raise("--duration #{duration}s is not billable on #{model_name}")

    resolution = opts[:resolution] || spec.default_resolution

    rate =
      Map.get(spec.rates, resolution) ||
        Mix.raise("#{model_name} has no #{resolution} (options: #{Enum.join(Map.keys(spec.rates), " | ")})")

    cost = Float.round(duration * rate, 3)

    promo_note =
      if spec.promo, do: " (launch promo — roughly double after it ends)", else: ""

    Mix.shell().info("── #{model_name} #{resolution} #{duration}s → ~$#{cost}#{promo_note} ──")

    # Boot for the same reasons sinestesia.video does: runtime.exs is what
    # loads .env (the API keys live there), and Req needs Finch running.
    System.put_env("PORT", System.get_env("REPLAY_PORT", "4999"))
    Mix.Task.run("app.start")

    out = opts[:out] || "motion-#{System.system_time(:second)}.mp4"

    Mix.shell().info("[motion] submitting to #{model_name}")

    with {:ok, ref} <-
           engine.submit(prompt, from,
             to: to,
             duration: duration,
             resolution: resolution,
             model: model_name
           ),
         {:ok, path} <- engine.await(ref, out) do
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
            "[--model veo-fast|veo-lite|veo|h3-max|h3] [--duration S] [--resolution R] [--out PATH]"
        )
    end
  end
end
