# Generate 3 accumulative image sequences for transition testing in the frontend.
#
# Standalone — does NOT boot the full app. Safe to run while the backend
# is also running on :4000.
#
# Run from backend/:
#   mix run --no-start scripts/gen_test_images.exs
#
# Output:
#   frontend/public/samples/
#     index.json                       — list of all sequences with metadata
#     aquarela/
#       frame_01.jpg .. frame_06.jpg
#       manifest.json
#     cityscape/
#       ...
#     cosmic/
#       ...
#
# The frontend can fetch /samples/index.json at dev time to populate a
# "sample sequences" picker for testing transitions without singing.

{:ok, _} = Application.ensure_all_started(:req)

env_path = Path.expand("../.env", __DIR__)

fal_key =
  case File.read(env_path) do
    {:ok, body} ->
      body
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(line, "=", parts: 2) do
          ["FAL_API_KEY", v] -> v |> String.trim() |> String.trim("\"")
          _ -> nil
        end
      end)

    _ ->
      System.get_env("FAL_API_KEY")
  end

if is_nil(fal_key) or fal_key == "" do
  IO.puts("ERROR: FAL_API_KEY not found in #{env_path} or env. Aborting.")
  System.halt(1)
end

out_root = Path.expand("../../frontend/public/samples", __DIR__)
File.mkdir_p!(out_root)

# Three sequences with distinct themes/styles, each 6 frames.
sequences = [
  %{
    slug: "aquarela",
    title: "Aquarela — childlike progression",
    description: "Sun → castle → glove → rain → road → sailboat. Inspired by Toquinho's 'Aquarela'.",
    style: "loose ink sketch on aged paper, sparse hand-drawn linework, sepia tones",
    prompts: [
      "a single round sun in the upper corner of the page",
      "a single round sun, and a small castle with simple square towers below",
      "a single round sun, a small castle below, and an outlined glove at the edge of the page",
      "a single round sun, a small castle, an outlined glove, and a cloud with diagonal rain lines",
      "a single round sun, a small castle, a glove, rain clouds, and a winding road leading toward the horizon",
      "a single round sun, a small castle, a glove, rain clouds, a winding road, and a small sailboat drifting on a calm sea"
    ]
  },
  %{
    slug: "cityscape",
    title: "Cityscape — urban growth",
    description: "Building → street → cars → pedestrians → night lights → rain on windows.",
    style: "graffiti marker on concrete wall, raw bold outlines, urban",
    prompts: [
      "a tall narrow building at the center of the wall",
      "a tall narrow building and a wide street stretching across the foreground",
      "a tall narrow building, a wide street, and small angular cars parked along the curb",
      "a tall narrow building, a wide street, parked cars, and silhouettes of pedestrians walking",
      "a tall narrow building, a wide street, cars, pedestrians, and bright window lights glowing in the night",
      "a tall narrow building, a wide street, cars, pedestrians, window lights, and rain streaks slanting across the whole scene"
    ]
  },
  %{
    slug: "cosmic",
    title: "Cosmic — slow celestial assembly",
    description: "Moon → stars → comet → planet → orbital ring → distant nebula.",
    style: "watercolor and ink, pale washes, hand-drawn outlines",
    prompts: [
      "a crescent moon floating in an empty dark sky",
      "a crescent moon and a scattering of small bright stars across the sky",
      "a crescent moon, scattered stars, and a long comet streaking diagonally past",
      "a crescent moon, scattered stars, a comet, and a large ringed planet rising at the horizon",
      "a crescent moon, scattered stars, a comet, a ringed planet, and a thin orbital ring of debris around the planet",
      "a crescent moon, scattered stars, a comet, a ringed planet, an orbital ring, and a faint glowing nebula spreading across the background"
    ]
  }
]

headers = [{"authorization", "Key " <> fal_key}]

gen_first = fn prompt, style ->
  full = "A hand-drawn scene showing #{prompt}. #{style}"
  body = %{
    prompt: full,
    image_size: "landscape_16_9",
    num_inference_steps: 4,
    enable_safety_checker: false
  }

  resp =
    Req.post("https://fal.run/fal-ai/flux/schnell",
      json: body,
      headers: headers,
      receive_timeout: 30_000,
      retry: false
    )

  {full, resp}
end

gen_next = fn prompt, style, prev_url ->
  full = "A hand-drawn scene showing #{prompt}. #{style}"
  body = %{
    prompt: full,
    image_url: prev_url,
    strength: 0.55,
    num_inference_steps: 10,
    image_size: "landscape_16_9",
    enable_safety_checker: false
  }

  resp =
    Req.post("https://fal.run/fal-ai/flux/dev/image-to-image",
      json: body,
      headers: headers,
      receive_timeout: 30_000,
      retry: false
    )

  {full, resp}
end

download = fn url, path ->
  case Req.get(url, receive_timeout: 30_000) do
    {:ok, %{status: 200, body: body}} ->
      File.write!(path, body)
      :ok

    other ->
      IO.puts("    WARN: download failed → #{inspect(other)}")
      :error
  end
end

run_sequence = fn seq ->
  IO.puts("\n=== #{seq.title} (#{seq.slug}) ===")
  seq_dir = Path.join(out_root, seq.slug)
  File.mkdir_p!(seq_dir)

  results =
    seq.prompts
    |> Enum.with_index(1)
    |> Enum.reduce({nil, []}, fn {prompt, i}, {prev_url, acc} ->
      IO.puts("\n  [#{i}/#{length(seq.prompts)}] #{prompt}")
      t0 = System.monotonic_time(:millisecond)

      {full_prompt, response} =
        if prev_url, do: gen_next.(prompt, seq.style, prev_url), else: gen_first.(prompt, seq.style)

      case response do
        {:ok, %{status: 200, body: %{"images" => [%{"url" => url} | _]}}} ->
          dt = System.monotonic_time(:millisecond) - t0
          filename = "frame_#{String.pad_leading(to_string(i), 2, "0")}.jpg"
          path = Path.join(seq_dir, filename)
          IO.puts("    → #{url}")
          download.(url, path)
          IO.puts("    ↓ #{filename} (#{dt}ms)")

          entry = %{
            idx: i,
            file: filename,
            url: url,
            prompt: full_prompt,
            latency_ms: dt
          }

          {url, [entry | acc]}

        other ->
          IO.puts("    ERROR: #{inspect(other)}")
          {prev_url, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()

  manifest = %{
    slug: seq.slug,
    title: seq.title,
    description: seq.description,
    style: seq.style,
    frames: results
  }

  File.write!(Path.join(seq_dir, "manifest.json"), Jason.encode!(manifest, pretty: true))
  manifest
end

manifests = Enum.map(sequences, run_sequence)

# Top-level index for the frontend picker
index = %{
  generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  sequences:
    Enum.map(manifests, fn m ->
      %{
        slug: m.slug,
        title: m.title,
        description: m.description,
        style: m.style,
        frame_count: length(m.frames),
        frames:
          Enum.map(m.frames, fn f ->
            %{idx: f.idx, file: "#{m.slug}/#{f.file}", prompt: f.prompt}
          end)
      }
    end)
}

File.write!(Path.join(out_root, "index.json"), Jason.encode!(index, pretty: true))

IO.puts("\n✓ Done. #{length(manifests)} sequences, #{Enum.sum(Enum.map(manifests, &length(&1.frames)))} total frames")
IO.puts("  Root:  #{out_root}")
IO.puts("  Index: #{Path.join(out_root, "index.json")}")
IO.puts("  Frontend dev URL: http://localhost:5173/samples/index.json")
