defmodule Mix.Tasks.Sinestesia.Replay do
  @shortdoc "Replay a recorded session headlessly through the full pipeline"
  @moduledoc """
  Replays a session file (see `tests/sessions/`) through the real pipeline —
  Director (Gemma), image generation (local SDXL / fal bootstrap) — with no
  browser and no mic, printing every image as it lands.

      mix sinestesia.replay ../tests/sessions/aquarela-tarsila.json
      REPLAY_SPEED=2 mix sinestesia.replay ../tests/sessions/aquarela-tarsila.json

  Runs on PORT=4999 by default so it can coexist with a live backend on :4000
  (override with REPLAY_PORT). Requires the same services as a live run:
  Ollama (Director), the local-sdxl sidecar, and FAL_API_KEY for the first
  frame.

  After the run, the generated images are exported as a frontend sample
  sequence under `frontend/public/samples/` so the whole run can be WATCHED
  with the continuous-morph demo player:

      http://localhost:5173/?demo=run-<session-name>

  The default slug (`run-<session-name>`) is overwritten on each run — iterate
  freely. Pass `--slug my-experiment` to keep a run for A/B comparison.
  """
  use Mix.Task
  require Logger

  @impl true
  def run(args) do
    {file, opts} = parse_args(args)

    System.put_env("STT_PROVIDER", "replay")
    System.put_env("REPLAY_FILE", Path.expand(file))
    if opts[:speed], do: System.put_env("REPLAY_SPEED", opts[:speed])
    System.put_env("PORT", System.get_env("REPLAY_PORT", "4999"))

    Mix.Task.run("app.start")

    session = file |> File.read!() |> Jason.decode!()
    name = session["name"] || Path.basename(file, ".json")
    duration_ms = session["events"] |> List.last() |> Map.fetch!("at_ms")
    speed_f = parse_speed(opts[:speed])
    # Generous budget: playback time + 30s for trailing director/image work.
    deadline_ms = round(duration_ms / speed_f) + 30_000

    parent = self()
    socket = spawn(fn -> socket_loop(parent) end)
    {:ok, _pipeline} = Sinestesia.Pipeline.start_link(socket)

    Mix.shell().info("── replaying #{name} (#{length(session["events"])} events) ──")

    acc =
      collect(deadline_ms, %{
        images: [],
        style: session["style"],
        started_at: now_ms(),
        done?: false
      })

    export_demo(acc, name, opts[:slug] || "run-#{name}", speed_f)
  end

  # Fake AudioSocket: forwards every pipeline push to the task process.
  defp socket_loop(parent) do
    receive do
      {:push_json, msg} -> send(parent, {:pushed, msg})
      _ -> :ok
    end

    socket_loop(parent)
  end

  defp collect(deadline_ms, acc) do
    remaining = deadline_ms - (now_ms() - acc.started_at)

    receive do
      {:pushed, %{type: "image"} = msg} ->
        n = length(acc.images) + 1
        t = msg.timings
        frames = Map.get(msg, :frames, [])

        Mix.shell().info(
          "[#{pad(n)}] +#{div(now_ms() - acc.started_at, 1000)}s  " <>
            "(director #{t.director_ms}ms + image #{t.image_ms}ms#{frames_note(frames)})\n" <>
            "      #{msg.prompt}\n      #{msg.url}"
        )

        collect(deadline_ms, %{acc | images: acc.images ++ [Map.put(msg, :arrived_at, now_ms())]})

      {:pushed, %{type: "replay_done"}} ->
        # Playback finished; give trailing director/image tasks time to land.
        Mix.shell().info("── playback done, waiting for trailing work ──")
        collect(min(deadline_ms, now_ms() - acc.started_at + 15_000), %{acc | done?: true})

      {:pushed, %{type: "style"} = msg} ->
        collect(deadline_ms, %{acc | style: msg.style})

      {:pushed, %{type: "error"} = msg} ->
        Mix.shell().error("[error] #{inspect(msg)}")
        collect(deadline_ms, acc)

      {:pushed, _other} ->
        collect(deadline_ms, acc)
    after
      max(remaining, 0) -> summarize(acc)
    end
  end

  defp summarize(acc) do
    Mix.shell().info("\n── summary ──")
    Mix.shell().info("images: #{length(acc.images)}")

    if acc.images != [] do
      avg = fn key ->
        vals = Enum.map(acc.images, &Map.get(&1.timings, key)) |> Enum.reject(&is_nil/1)
        if vals == [], do: 0, else: div(Enum.sum(vals), length(vals))
      end

      Mix.shell().info("avg director: #{avg.(:director_ms)}ms, avg image: #{avg.(:image_ms)}ms")
    end

    acc
  end

  # ── Demo export: turn the run into a frontend sample sequence ──────────────
  #
  # Writes frames + index entry in the exact format of `frontend/public/samples`
  # (see frontend/src/samples.ts), so the run is watchable with the existing
  # continuous-morph player at ?demo=<slug>. Only the FINAL image of each cycle
  # is exported — the player supplies the morph between them; the sidecar's
  # latent morph frames are for the live path.

  defp export_demo(%{images: []}, _name, _slug, _speed) do
    Mix.shell().info("no images — nothing to export")
  end

  defp export_demo(acc, name, slug, speed) do
    samples_dir = Path.expand("../frontend/public/samples")

    if File.dir?(samples_dir) do
      do_export(acc, name, slug, samples_dir, speed)
    else
      Mix.shell().error("samples dir not found (#{samples_dir}) — skipping demo export")
    end
  end

  # Average measured gap between image arrivals, scaled back to live speed
  # (the replay compressed time by `speed`). This is what the demo player
  # should use as its per-transition duration so playback paces like the show.
  defp measured_segment_ms(images, speed) do
    arrivals = Enum.map(images, & &1.arrived_at)

    case arrivals do
      [_single] ->
        5500

      many ->
        # Median, not mean: a single slow image (cold model, slow fal CDN
        # fetch) would otherwise inflate the whole playback pacing.
        gaps =
          many
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [a, b] -> b - a end)
          |> Enum.sort()

        median = Enum.at(gaps, div(length(gaps), 2))
        (median * speed) |> round() |> max(1500) |> min(8000)
    end
  end

  defp do_export(acc, name, slug, samples_dir, speed) do
    dir = Path.join(samples_dir, slug)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    frames =
      acc.images
      |> Enum.with_index(1)
      |> Enum.map(fn {msg, i} ->
        ext = if String.contains?(msg.url, ".jpg"), do: "jpg", else: "png"
        file = "frame_#{String.pad_leading(to_string(i), 2, "0")}.#{ext}"
        %{status: 200, body: body} = Req.get!(msg.url, retry: false, decode_body: false)
        File.write!(Path.join(dir, file), body)

        %{
          "idx" => i,
          "file" => "#{slug}/#{file}",
          "prompt" => msg.prompt,
          "lyric" => Map.get(msg, :lyric)
        }
      end)

    index_path = Path.join(samples_dir, "index.json")

    index =
      if File.exists?(index_path),
        do: index_path |> File.read!() |> Jason.decode!(),
        else: %{"sequences" => []}

    entry = %{
      "slug" => slug,
      "title" => "Replay: #{name}",
      "description" =>
        "Pipeline replay of #{name} on #{Date.utc_today()} — #{length(frames)} images.",
      "style" => acc.style || "",
      # Real cadence of this run (live-speed equivalent). The demo player can
      # use this as its per-transition duration instead of the hardcoded 5500.
      "segment_ms" => measured_segment_ms(acc.images, speed),
      "frames" => frames,
      "frame_count" => length(frames)
    }

    sequences =
      (index["sequences"] || [])
      |> Enum.reject(&(&1["slug"] == slug))
      |> Kernel.++([entry])

    File.write!(index_path, Jason.encode!(%{"sequences" => sequences}, pretty: true) <> "\n")

    Mix.shell().info(
      "\n── demo exported ──\n#{length(frames)} frames → #{dir}\nwatch it: http://localhost:5173/?demo=#{slug}"
    )
  end

  defp frames_note([]), do: ""
  defp frames_note(frames), do: ", #{length(frames)} morph frames"

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [speed: :string, slug: :string]) do
      {opts, [file], []} -> {file, opts}
      _ -> Mix.raise("usage: mix sinestesia.replay <session.json> [--speed N] [--slug name]")
    end
  end

  defp parse_speed(nil), do: 1.0

  defp parse_speed(s) do
    case Float.parse(s) do
      {f, _} when f > 0 -> f
      _ -> 1.0
    end
  end

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")
  defp now_ms, do: System.system_time(:millisecond)
end
