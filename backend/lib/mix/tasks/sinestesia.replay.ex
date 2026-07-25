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
    env_speed = System.get_env("REPLAY_SPEED")
    speed_f =
      cond do
        opts[:speed] -> parse_speed(opts[:speed])
        env_speed -> parse_speed(env_speed)
        true -> 1.0
      end
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

    export_demo(acc, session, name, opts[:slug] || "run-#{name}", speed_f)
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

  defp export_demo(%{images: []}, _session, _name, _slug, _speed) do
    Mix.shell().info("no images — nothing to export")
  end

  defp export_demo(acc, session, name, slug, speed) do
    samples_dir = Path.expand("../frontend/public/samples")

    if File.dir?(samples_dir) do
      do_export(acc, session, name, slug, samples_dir, speed)
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

  defp do_export(acc, session, name, slug, samples_dir, speed) do
    dir = Path.join(samples_dir, slug)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    # First, calculate monotonic, song-relative at_ms for each image message
    images_with_at =
      acc.images
      |> Enum.scan({-1, nil}, fn msg, {prev_at, _} ->
        event_fired_wall_ms = msg.arrived_at - Map.get(msg.timings, :total_ms, 0) - acc.started_at
        calculated_at = round(event_fired_wall_ms * speed)
        at_ms = max(prev_at + 1, max(calculated_at, 0))
        {at_ms, Map.put(msg, :at_ms, at_ms)}
      end)
      |> Enum.map(fn {_, msg} -> msg end)

    frames =
      images_with_at
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {msg, k} ->
        subframes = Map.get(msg, :frames, []) || []
        subframe_count = length(subframes)

        # Segment duration until the next image (to scale the step duration)
        next_msg = Enum.at(images_with_at, k)
        segment_dur = if next_msg, do: next_msg.at_ms - msg.at_ms, else: 10_000

        if subframes == [] do
          {ext, body} = fetch_image(msg.url)
          pad_k = String.pad_leading(to_string(k), 2, "0")

          if k == 1 do
            file = "frame_#{pad_k}.jpg"
            write_as_jpg(Path.join(dir, file), ext, body)

            [
              %{
                "idx" => k,
                "file" => "#{slug}/#{file}",
                "prompt" => msg.prompt,
                "lyric" => Map.get(msg, :lyric),
                "at_ms" => msg.at_ms
              }
            ]
          else
            # Find the previous frame file on disk
            prev_pad = String.pad_leading(to_string(k - 1), 2, "0")
            matching_files = Path.wildcard(Path.join(dir, "frame_#{prev_pad}*"))

            case matching_files |> Enum.sort() |> List.last() do
              nil ->
                file = "frame_#{pad_k}.jpg"
                write_as_jpg(Path.join(dir, file), ext, body)

                [
                  %{
                    "idx" => k,
                    "file" => "#{slug}/#{file}",
                    "prompt" => msg.prompt,
                    "lyric" => Map.get(msg, :lyric),
                    "at_ms" => msg.at_ms
                  }
                ]

              prev_file_path ->
                # Write current target image temporarily
                target_file_name = "frame_#{pad_k}_target.jpg"
                target_path = Path.join(dir, target_file_name)
                write_as_jpg(target_path, ext, body)

                # Generate 12 intermediate synthetic morph frames
                steps = 12
                total_frames = steps + 1
                step_dur = max(20, min(100, div(segment_dur, total_frames * 2)))

                subframe_entries =
                  1..steps
                  |> Enum.map(fn j ->
                    t = j / total_frames
                    sub_file_name = "frame_#{pad_k}_m#{String.pad_leading(to_string(j), 2, "0")}.jpg"
                    sub_path = Path.join(dir, sub_file_name)

                    t_str = :erlang.float_to_binary(t, [decimals: 4])

                    run_cmd!("ffmpeg", [
                      "-y",
                      "-i", prev_file_path,
                      "-i", target_path,
                      "-filter_complex", "blend=all_expr='A*(1-#{t_str})+B*#{t_str}'",
                      "-frames:v", "1",
                      sub_path
                    ])

                    frame_at_ms = msg.at_ms + (j - 1) * step_dur

                    %{
                      "idx" => k,
                      "file" => "#{slug}/#{sub_file_name}",
                      "prompt" => msg.prompt,
                      "lyric" => Map.get(msg, :lyric),
                      "at_ms" => frame_at_ms
                    }
                  end)

                # Rename the temporary target to become the final frame (m13)
                final_file_name = "frame_#{pad_k}_m#{String.pad_leading(to_string(total_frames), 2, "0")}.jpg"
                final_path = Path.join(dir, final_file_name)
                File.rename!(target_path, final_path)

                final_at_ms = msg.at_ms + steps * step_dur
                final_entry = %{
                  "idx" => k,
                  "file" => "#{slug}/#{final_file_name}",
                  "prompt" => msg.prompt,
                  "lyric" => Map.get(msg, :lyric),
                  "at_ms" => final_at_ms
                }

                subframe_entries ++ [final_entry]
            end
          end
        else
          # Download and export each subframe sequentially
          step_dur =
            if k == 1 do
              100
            else
              max(20, min(100, div(segment_dur, subframe_count * 2)))
            end

          subframes
          |> Enum.with_index(1)
          |> Enum.map(fn {sub_url, j} ->
            {ext, body} = fetch_image(sub_url)
            file = "frame_#{String.pad_leading(to_string(k), 2, "0")}_m#{String.pad_leading(to_string(j), 2, "0")}.jpg"
            write_as_jpg(Path.join(dir, file), ext, body)

            frame_at_ms = msg.at_ms + (j - 1) * step_dur

            %{
              "idx" => k,
              "file" => "#{slug}/#{file}",
              "prompt" => msg.prompt,
              "lyric" => Map.get(msg, :lyric),
              "at_ms" => frame_at_ms
            }
          end)
        end
      end)

    # Copy audio and compile MP4 video if original audio is available
    audio_path = session["audio"]

    {audio_rel, video_rel} =
      if audio_path && File.exists?(audio_path) do
        try do
          # Copy original audio retention extension
          audio_ext = Path.extname(audio_path) |> String.downcase()
          audio_filename = "audio#{audio_ext}"
          audio_dest = Path.join(dir, audio_filename)
          {:ok, _} = File.copy(audio_path, audio_dest)

          # Query audio duration
          audio_duration_str = run_cmd!("ffprobe", [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            audio_dest
          ])
          {audio_duration, _} = Float.parse(audio_duration_str)

          # Prepend a matching black.png if there's a musical introduction
          first_frame = List.first(frames)
          first_frame_at_ms = first_frame["at_ms"]

          if first_frame_at_ms > 0 do
            first_frame_path = Path.join(dir, Path.basename(first_frame["file"]))
            probe_out = run_cmd!("ffprobe", [
              "-v", "error",
              "-select_streams", "v:0",
              "-show_entries", "stream=width,height",
              "-of", "csv=s=x:p=0",
              first_frame_path
            ])
            [width_str, height_str] = String.split(probe_out, "x")
            width = String.to_integer(String.trim(width_str))
            height = String.to_integer(String.trim(height_str))

            black_path = Path.join(dir, "black.jpg")
            run_cmd!("ffmpeg", [
              "-y",
              "-f", "lavfi",
              "-i", "color=c=black:s=#{width}x#{height}",
              "-vframes", "1",
              black_path
            ])
          end

          # Format ffmpeg concat file
          intro_lines =
            if first_frame_at_ms > 0 do
              intro_sec = first_frame_at_ms / 1000.0
              ["file 'black.jpg'", "duration #{intro_sec}"]
            else
              []
            end

          middle_lines =
            frames
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.flat_map(fn [f1, f2] ->
              dur = (f2["at_ms"] - f1["at_ms"]) / 1000.0
              dur = max(dur, 0.001)
              basename = Path.basename(f1["file"])
              ["file '#{basename}'", "duration #{dur}"]
            end)

          last_frame = List.last(frames)
          last_basename = Path.basename(last_frame["file"])
          last_dur = audio_duration - (last_frame["at_ms"] / 1000.0)
          last_dur = max(last_dur, 0.001)

          final_lines = [
            "file '#{last_basename}'",
            "duration #{last_dur}",
            "file '#{last_basename}'"
          ]

          input_txt_content = (intro_lines ++ middle_lines ++ final_lines) |> Enum.join("\n")
          input_txt_path = Path.join(dir, "input.txt")
          File.write!(input_txt_path, input_txt_content <> "\n")

          # Compile MP4 video with H.264 & AAC audio
          video_dest = Path.join(dir, "video.mp4")
          run_cmd!("ffmpeg", [
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", input_txt_path,
            "-i", audio_dest,
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-preset", "veryfast",
            "-crf", "22",
            "-c:a", "aac",
            "-shortest",
            video_dest
          ])

          # Clean up temporary frames
          if first_frame_at_ms > 0, do: File.rm(Path.join(dir, "black.jpg"))
          File.rm(input_txt_path)

          {"#{slug}/#{audio_filename}", "#{slug}/video.mp4"}
        rescue
          err ->
            Mix.shell().error("Failed to compile synchronized video: #{inspect(err)}")
            {nil, nil}
        end
      else
        {nil, nil}
      end

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
      "params" => run_params(),
      "segment_ms" => measured_segment_ms(acc.images, speed),
      "frames" => frames,
      "frame_count" => length(frames)
    }
    |> then(fn m -> if audio_rel, do: Map.put(m, "audio", audio_rel), else: m end)
    |> then(fn m -> if video_rel, do: Map.put(m, "video", video_rel), else: m end)

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
      # Normalised, not raw: RENDER_MODE accepts several legacy spellings, and
      # an export that says "img2img" on one run and "i2i" on the next is not
      # comparable with itself.
      "render_mode" => to_string(Sinestesia.ImageGen.render_mode()),
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

  defp run_cmd!(cmd, args, cd \\ nil) do
    opts = if cd, do: [cd: cd, stderr_to_stdout: true], else: [stderr_to_stdout: true]
    case System.cmd(cmd, args, opts) do
      {output, 0} ->
        output |> String.trim()

      {output, status} ->
        Mix.shell().error("Failed to run #{cmd} #{Enum.join(args, " ")} (status #{status}):\n#{output}")
        raise "Command failed"
    end
  end

  defp write_as_jpg(dest_path, ext, body) do
    if ext == "jpg" do
      File.write!(dest_path, body)
    else
      temp_path = dest_path <> ".tmp.png"
      File.write!(temp_path, body)
      try do
        run_cmd!("ffmpeg", [
          "-y",
          "-i", temp_path,
          "-q:v", "2",
          dest_path
        ])
      after
        File.rm(temp_path)
      end
    end
  end
end
