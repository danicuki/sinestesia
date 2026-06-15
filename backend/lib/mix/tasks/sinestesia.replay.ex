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

    Mix.shell().info(
      "── params: " <>
        (run_params()
         |> Map.delete("exported_at")
         |> Enum.sort()
         |> Enum.map_join("  ", fn {k, v} -> "#{k}=#{v}" end))
    )

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
            "      #{msg.prompt}\n      #{display_url(msg.url)}"
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
      |> Enum.flat_map(fn {msg, i} ->
        subframes = Map.get(msg, :frames, []) || []

        if subframes == [] do
          {ext, body} = fetch_image(msg.url)
          file = "frame_#{String.pad_leading(to_string(i), 2, "0")}.#{ext}"
          File.write!(Path.join(dir, file), body)

          [
            %{
              "idx" => i,
              "file" => "#{slug}/#{file}",
              "prompt" => msg.prompt,
              "lyric" => Map.get(msg, :lyric)
            }
          ]
        else
          # Download and export each subframe sequentially
          subframes
          |> Enum.with_index(1)
          |> Enum.map(fn {sub_url, j} ->
            {ext, body} = fetch_image(sub_url)
            file = "frame_#{String.pad_leading(to_string(i), 2, "0")}_m#{String.pad_leading(to_string(j), 2, "0")}.#{ext}"
            File.write!(Path.join(dir, file), body)

            %{
              "idx" => i,
              "file" => "#{slug}/#{file}",
              "prompt" => msg.prompt,
              "lyric" => Map.get(msg, :lyric)
            }
          end)
        end
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
      # Every knob that shaped this run — so A/B results stay comparable
      # after you've forgotten what you set.
      "params" => run_params(),
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

  # The full recipe of the run. Defaults are spelled out (not omitted) so an
  # old export stays interpretable even after defaults change in code.
  defp run_params do
    base = %{
      "image_provider" => System.get_env("IMAGE_PROVIDER", "fal"),
      "render_mode" => System.get_env("RENDER_MODE", "img2img"),
      "image_mode" => System.get_env("IMAGE_MODE", "story"),
      "compose_mode" => System.get_env("COMPOSE_MODE", "inpaint"),
      "director_provider" => System.get_env("DIRECTOR_PROVIDER", "gemma"),
      "scene_window" => System.get_env("SCENE_WINDOW", "5"),
      "style_anchor" => System.get_env("STYLE_ANCHOR", "(off)"),
      "style_refresh_every" => System.get_env("STYLE_REFRESH_EVERY", "4"),
      "replay_file" => System.get_env("REPLAY_FILE", "") |> Path.basename(),
      "replay_speed" => System.get_env("REPLAY_SPEED", "1.0"),
      "exported_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> to_string()
    }

    provider_knobs =
      case System.get_env("IMAGE_PROVIDER", "fal") do
        "local" <> _ ->
          %{
            "local_sdxl_strength" => System.get_env("LOCAL_SDXL_STRENGTH", "0.78"),
            "local_sdxl_steps" => System.get_env("LOCAL_SDXL_STEPS", "3"),
            "compose_atmos_strength" => System.get_env("COMPOSE_ATMOS_STRENGTH", "0.4")
          }

        "c" <> _ ->
          %{
            "cloudflare_strength" => System.get_env("CLOUDFLARE_STRENGTH", "0.7"),
            "cloudflare_steps" => System.get_env("CLOUDFLARE_STEPS", "20"),
            "cloudflare_guidance" => System.get_env("CLOUDFLARE_GUIDANCE", "7.5"),
            "cloudflare_img2img_model" =>
              System.get_env(
                "CLOUDFLARE_IMG2IMG_MODEL",
                "@cf/runwayml/stable-diffusion-v1-5-img2img"
              )
          }

        _ ->
          %{}
      end

    Map.merge(base, provider_knobs)
  end

  # Providers like cloudflare/google hand back data URLs — decode them
  # locally instead of asking Finch to "fetch" a megabyte-long URL.
  defp fetch_image("data:image/" <> rest = _url) do
    [meta, b64] = String.split(rest, ",", parts: 2)
    ext = if String.starts_with?(meta, "jpeg"), do: "jpg", else: "png"
    {ext, Base.decode64!(b64)}
  end

  defp fetch_image(url) do
    ext = if String.contains?(url, ".jpg"), do: "jpg", else: "png"
    %{status: 200, body: body} = Req.get!(url, retry: false, decode_body: false)
    {ext, body}
  end

  # Never print a full data URL — it floods the terminal with base64.
  defp display_url("data:image/" <> _ = url),
    do: "data URL (#{div(byte_size(url), 1024)} KB)"

  defp display_url(url), do: url

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
