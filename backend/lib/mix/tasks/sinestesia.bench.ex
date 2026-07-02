defmodule Mix.Tasks.Sinestesia.Bench do
  @shortdoc "Benchmark performance & cost of the pluggable stack providers (image, ...)"
  @moduledoc """
  Compare latency and cost across the swappable providers of the Sinestesia
  stack. Today the stack has three pluggable stages — STT, Director, and image
  generation — and each one trades time against money differently. This task
  runs the same work against several providers back-to-back and prints a
  side-by-side table so the trade-off is legible.

  The image stage is the one implemented here (the current priority). The
  `stt` and `director` stages are scaffolded and will tell you they're not
  wired up yet.

  ## Image stage

      mix sinestesia.bench image
      mix sinestesia.bench image --providers fal,google,ramen,cloudflare,local
      mix sinestesia.bench image --modes t2i,i2i --runs 5 --warmup

  Image generation comes in two flavours and the task benchmarks both:

    * `t2i` — text-to-image (a frame rendered from scratch)
    * `i2i` — image-to-image (a frame that evolves a previous one)

  Providers (`--providers`, comma-separated, default = all that have a key):

    | name         | t2i | i2i | notes                                          |
    |--------------|-----|-----|------------------------------------------------|
    | `fal`        |  ✓  |  ✓  | Flux Schnell (t2i) / Flux dev (i2i), paid      |
    | `google`     |  ✓  |  —  | Imagen 4 Fast — text-to-image only             |
    | `ramen`      |  ✓  |  ✓  | Google early-access "instant ramen" model      |
    | `cloudflare` |  ✓  |  ✓  | Workers AI (Flux schnell / SD 1.5), credits    |
    | `local`      |  ✓  |  ✓  | local SDXL Turbo sidecar (port 8003), free     |

  The early-access **instant ramen** model is benchmarked via `ramen`, which
  talks to Google's Gemini `:generateContent` image endpoint
  (`Sinestesia.ImageGen.GeminiImage`) — that's the API this model family uses,
  and it does both t2i and i2i through the same call. The "instant ramen"
  codename shipped as `gemini-3.1-flash-lite-image` (the default); override with
  `GOOGLE_RAMEN_MODEL` (a `models/` prefix is stripped).

  ## Output

  Each run writes a `bench-<timestamp>/` directory containing:

    * `bench-<timestamp>.txt` — the full results table (same as stdout)
    * `<provider>-<mode>.png|jpg` — one representative generated image per
      candidate, for visual inspection

  Override the directory with `BENCH_OUT`.

  ## Options

    * `--providers a,b,c`  which providers to test (default: all configured)
    * `--modes t2i,i2i`    which image modes to test (default: both)
    * `--runs N`           timed iterations per provider×mode (default: 3)
    * `--warmup`           do one extra untimed run first (fair to cold local
                           models and warm CDN caches; recommended)
    * `--prompt "..."`     the text prompt (a default is provided)
    * `--seed-image PATH`  i2i seed image: a local file or http(s) URL
                           (default: a bundled aquarela sample frame)

  ## Cost

  Per-image USD prices live in `@pricing` at the top of this module. They are
  **estimates** — fal bills per megapixel, Cloudflare draws from startup
  credits (counted as $0), local is your own electricity ($0). Edit the map to
  match your actual rates; the early-access ramen price is unknown, so update
  it once you know.

  Requires the relevant keys in `.env` (FAL_API_KEY, GOOGLE_API_KEY,
  CLOUDFLARE_*) and, for `local`, the SDXL sidecar running on port 8003.
  """
  use Mix.Task

  alias Sinestesia.ImageGen

  # ── Per-image cost (USD), validated against public pricing pages 2026-06. ───
  # Keyed "<provider>:<mode>". These assume the standardized 1024x576 (~0.59 MP)
  # output (Google Imagen is the exception — fixed 1408x768, see below).
  #
  #   fal        per megapixel, billed ROUNDED UP to the next whole MP, so a
  #              0.59 MP frame bills as 1 MP. schnell $0.003/MP, dev i2i
  #              $0.03/MP. (fal.ai/docs/.../pricing)
  #   google     Imagen 4 Fast, flat $0.02/image (ai.google.dev/pricing).
  #              NOTE: Imagen 4 is deprecated, shutting down 2026-08-17 — the
  #              `ramen` model (gemini-3.1-flash-lite-image) is the migration.
  #   cloudflare NOT free — billed in neurons ($0.011 / 1,000 neurons; first
  #              10,000 neurons/day free). Your runs read $0 only because they
  #              fit the free daily allotment / your credits. These SDXL models
  #              list ~$0.00/step, so per-image is well under $0.001 — rough
  #              estimate below; replace once you read your real neuron spend.
  #   local      your own hardware, no API charge.
  @pricing %{
    "fal:t2i" => 0.003,
    "fal:i2i" => 0.03,
    "google:t2i" => 0.02,
    # ramen = gemini-3.1-flash-lite-image; placeholder until public pricing is confirmed.
    "ramen:t2i" => 0.02,
    "ramen:i2i" => 0.02,
    "cloudflare:t2i" => 0.0008,
    "cloudflare:i2i" => 0.0008,
    "local:t2i" => 0.0,
    "local:i2i" => 0.0
  }

  @all_providers ~w(fal google ramen cloudflare local)
  @all_modes ~w(t2i i2i)

  @default_prompt "a sweeping watercolor landscape at golden hour, distant mountains, a winding river, loose expressive brushwork"

  # Which (provider, mode) pairs are even attemptable. Google Imagen is t2i-only.
  @supported %{
    "fal" => ~w(t2i i2i),
    "google" => ~w(t2i),
    "ramen" => ~w(t2i i2i),
    "cloudflare" => ~w(t2i i2i),
    "local" => ~w(t2i i2i)
  }

  @impl true
  def run(args) do
    {stage, opts} = parse_args(args)

    # Boot config (.env → application env) without colliding with a live server.
    System.put_env("PORT", System.get_env("BENCH_PORT", "4998"))
    Mix.Task.run("app.start")

    case stage do
      "image" -> bench_image(opts)
      "stt" -> not_implemented("stt")
      "director" -> not_implemented("director")
      other -> Mix.raise("unknown stage #{inspect(other)} — try: image | stt | director")
    end
  end

  # ── Image stage ────────────────────────────────────────────────────────────

  defp bench_image(opts) do
    providers = opts[:providers] || @all_providers
    modes = opts[:modes] || @all_modes
    runs = opts[:runs] || 3
    prompt = opts[:prompt] || @default_prompt
    warmup? = opts[:warmup] || false

    seed = if "i2i" in modes, do: load_seed(opts[:seed_image]), else: nil

    ts = timestamp()
    out_dir = Path.expand(System.get_env("BENCH_OUT", "bench-#{ts}"))
    File.mkdir_p!(out_dir)

    header = [
      "── sinestesia image benchmark ──",
      "when:      #{ts}",
      "providers: #{Enum.join(providers, ", ")}",
      "modes:     #{Enum.join(modes, ", ")}",
      "runs:      #{runs}#{if warmup?, do: " (+1 warmup)", else: ""}",
      "prompt:    #{prompt}",
      if("i2i" in modes, do: "seed:      #{seed_label(opts[:seed_image])}", else: nil)
    ]

    Enum.each(header, fn l -> if l, do: Mix.shell().info(l) end)
    Mix.shell().info("")

    rows =
      for provider <- providers, mode <- modes do
        cond do
          mode not in @all_modes ->
            Mix.raise("unknown mode #{inspect(mode)} — use t2i and/or i2i")

          mode not in Map.get(@supported, provider, []) ->
            %{provider: provider, mode: mode, status: :unsupported}

          true ->
            run_candidate(provider, mode, prompt, seed, runs, warmup?, out_dir)
        end
      end

    report = Enum.join(Enum.filter(header, & &1), "\n") <> "\n\n" <> render_table(rows)

    txt_path = Path.join(out_dir, "bench-#{ts}.txt")
    File.write!(txt_path, report <> "\n")

    Mix.shell().info("\n" <> render_table(rows))
    Mix.shell().info("\nresults: #{txt_path}")
    Mix.shell().info("images:  #{out_dir}")
  end

  defp run_candidate(provider, mode, prompt, seed, runs, warmup?, out_dir) do
    fun = candidate_fun(provider, mode, prompt, seed)
    Mix.shell().info("→ #{provider} #{mode} ...")

    if warmup?, do: timed(fun)

    results = for _ <- 1..runs, do: timed(fun)
    {oks, errs} = Enum.split_with(results, fn {ok, _ms, _} -> ok == :ok end)
    times = Enum.map(oks, fn {_, ms, _} -> ms end)

    if errs != [] do
      {_, _, reason} = hd(errs)
      Mix.shell().info("   ⚠ #{length(errs)}/#{runs} failed — e.g. #{inspect(reason, limit: 4)}")
    end

    # Save one representative image (the last successful run) for inspection.
    {image_file, res} =
      case List.last(oks) do
        {:ok, _ms, payload} -> save_image(payload, provider, mode, out_dir)
        _ -> {nil, nil}
      end

    price = Map.get(@pricing, "#{provider}:#{mode}", nil)

    %{
      provider: provider,
      mode: mode,
      status: :ok,
      runs: runs,
      ok: length(oks),
      min: min_or_nil(times),
      median: median_or_nil(times),
      avg: avg_or_nil(times),
      price: price,
      total_cost: if(price, do: price * length(oks), else: nil),
      image: image_file,
      res: res
    }
  end

  # Each candidate normalizes its provider call to {:ok, _} | {:error, reason}.
  defp candidate_fun("fal", "t2i", prompt, _seed), do: fn -> ImageGen.Fal.generate(prompt) end
  defp candidate_fun("fal", "i2i", prompt, seed), do: fn -> ImageGen.FalImg2Img.generate(prompt, seed) end

  defp candidate_fun("google", "t2i", prompt, _seed), do: fn -> ImageGen.Google.generate(prompt) end

  # The "instant ramen" model is a Gemini :generateContent image model, so it
  # does both t2i and i2i through the same call (seed passed as image_url).
  defp candidate_fun("ramen", "t2i", prompt, _seed), do: fn -> ImageGen.GeminiImage.generate(prompt) end
  defp candidate_fun("ramen", "i2i", prompt, seed), do: fn -> ImageGen.GeminiImage.generate(prompt, image_url: seed) end

  defp candidate_fun("cloudflare", "t2i", prompt, _seed), do: fn -> ImageGen.Cloudflare.text2img(prompt) end
  defp candidate_fun("cloudflare", "i2i", prompt, seed), do: fn -> ImageGen.Cloudflare.img2img(prompt, seed) end

  defp candidate_fun("local", "t2i", prompt, _seed), do: fn -> ImageGen.LocalSdxl.generate(prompt, nil) end
  defp candidate_fun("local", "i2i", prompt, seed), do: fn -> ImageGen.LocalSdxl.generate(prompt, seed) end

  # :timer.tc returns microseconds; normalize the various provider shapes,
  # keeping the returned url/data-url payload so we can save the image.
  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    ms = div(us, 1000)

    case result do
      {:ok, payload} -> {:ok, ms, payload}
      {:ok, url, _frames} -> {:ok, ms, url}
      {:error, reason} -> {:error, ms, reason}
      other -> {:error, ms, {:unexpected, other}}
    end
  end

  # ── Saving generated images ──────────────────────────────────────────────────

  defp save_image(payload, provider, mode, out_dir) do
    case decode_image(payload) do
      {:ok, ext, bytes} ->
        name = "#{provider}-#{mode}.#{ext}"
        File.write!(Path.join(out_dir, name), bytes)
        {name, image_dimensions(bytes)}

      {:error, reason} ->
        Mix.shell().info("   (couldn't save #{provider} #{mode} image: #{inspect(reason, limit: 3)})")
        {nil, nil}
    end
  end

  # Read pixel dimensions straight from the file header — providers disagree on
  # aspect ratio (e.g. Cloudflare returns square), which matters for the 16:9
  # stage, so it's worth surfacing in the table.
  defp image_dimensions(<<137, 80, 78, 71, 13, 10, 26, 10, _len::32, "IHDR", w::32, h::32, _::binary>>),
    do: "#{w}x#{h}"

  defp image_dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg_dimensions(rest)
  defp image_dimensions(_), do: nil

  # Walk JPEG segments until a Start-Of-Frame marker carries the dimensions.
  @jpeg_sof [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
  defp jpeg_dimensions(<<0xFF, m, _len::16, _prec, h::16, w::16, _::binary>>) when m in @jpeg_sof,
    do: "#{w}x#{h}"

  defp jpeg_dimensions(<<0xFF, m, _::binary>> = data) when m in 0xD0..0xD9 or m == 0x01 do
    <<0xFF, _m, rest::binary>> = data
    jpeg_dimensions(rest)
  end

  defp jpeg_dimensions(<<0xFF, _m, len::16, payload::binary>>) do
    case payload do
      <<_::binary-size(len - 2), rest::binary>> -> jpeg_dimensions(rest)
      _ -> nil
    end
  end

  defp jpeg_dimensions(<<_skip, rest::binary>>), do: jpeg_dimensions(rest)
  defp jpeg_dimensions(_), do: nil

  defp decode_image("data:image/" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [meta, b64] ->
        ext = if String.starts_with?(meta, "jpeg") or String.starts_with?(meta, "jpg"), do: "jpg", else: "png"
        {:ok, ext, Base.decode64!(b64)}

      _ ->
        {:error, :bad_data_url}
    end
  end

  defp decode_image("http" <> _ = url) do
    case Req.get(url, retry: false, decode_body: false) do
      {:ok, %{status: 200, body: bytes}} ->
        ext = if String.contains?(url, ".jpg") or String.contains?(url, ".jpeg"), do: "jpg", else: "png"
        {:ok, ext, bytes}

      {:ok, %{status: status}} ->
        {:error, {:fetch, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_image(other), do: {:error, {:unrecognized_payload, other}}

  # ── Seed image for i2i ───────────────────────────────────────────────────────

  # fal & cloudflare accept data: URLs; the local sidecar fetches http(s). If
  # you benchmark `local i2i`, pass `--seed-image` with a reachable http URL.
  defp load_seed(nil) do
    default = Path.expand("../frontend/public/samples/aquarela/frame_01.jpg")

    if File.exists?(default) do
      to_data_url(default)
    else
      Mix.raise("default seed image not found at #{default} — pass --seed-image PATH|URL")
    end
  end

  defp load_seed("http" <> _ = url), do: url

  defp load_seed(path) do
    if File.exists?(path),
      do: to_data_url(path),
      else: Mix.raise("seed image not found: #{path}")
  end

  defp to_data_url(path) do
    mime = if Path.extname(path) in [".jpg", ".jpeg"], do: "jpeg", else: "png"
    "data:image/#{mime};base64," <> Base.encode64(File.read!(path))
  end

  # ── Output ──────────────────────────────────────────────────────────────────

  # Builds the whole results block as a string so it can be both printed and
  # written verbatim to the bench-<ts>.txt file.
  defp render_table(rows) do
    header = ["provider", "mode", "ok", "min ms", "med ms", "avg ms", "res", "$/img", "total $", "image"]

    body =
      Enum.map(rows, fn
        %{status: :unsupported} = r ->
          [r.provider, r.mode, "—", "unsupported", "", "", "", "", "", ""]

        r ->
          [
            r.provider,
            r.mode,
            "#{r.ok}/#{r.runs}",
            fmt_int(r.min),
            fmt_int(r.median),
            fmt_int(r.avg),
            r.res || "—",
            fmt_price(r.price),
            fmt_total(r.total_cost),
            r.image || "—"
          ]
      end)

    widths = col_widths([header | body])

    table =
      [header, :sep | body]
      |> Enum.map_join("\n", fn
        :sep -> sep(widths)
        cells -> fmt_row(cells, widths)
      end)

    fastest = rows |> Enum.filter(&(&1[:status] == :ok and &1.avg)) |> Enum.min_by(& &1.avg, fn -> nil end)

    footer =
      [
        if fastest do
          "fastest: #{fastest.provider} #{fastest.mode} @ #{fastest.avg}ms avg" <>
            if(fastest.price, do: " (#{fmt_price(fastest.price)}/img)", else: "")
        end,
        "note: $ figures are estimates from @pricing — edit them for your real rates."
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n")

    table <> "\n\n" <> footer
  end

  defp col_widths(rows) do
    cols = length(hd(rows))

    for i <- 0..(cols - 1) do
      rows |> Enum.map(&String.length(Enum.at(&1, i))) |> Enum.max()
    end
  end

  defp fmt_row(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {c, w} -> String.pad_trailing(c, w) end)
  end

  defp sep(widths), do: Enum.map_join(widths, "  ", &String.duplicate("─", &1))

  defp timestamp do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()

    :io_lib.format("~4..0B-~2..0B-~2..0B_~2..0B~2..0B~2..0B", [y, mo, d, h, mi, s])
    |> to_string()
  end

  defp seed_label(nil), do: "default aquarela sample frame (data URL)"
  defp seed_label("http" <> _ = url), do: url
  defp seed_label(path), do: path

  defp fmt_int(nil), do: "—"
  defp fmt_int(n), do: Integer.to_string(n)

  # $/img: 0.0 means the provider itself is free (local / credits).
  defp fmt_price(nil), do: "?"
  defp fmt_price(0.0), do: "free"
  defp fmt_price(p) when is_float(p), do: "$" <> :erlang.float_to_binary(p, decimals: 4)

  # total: always a dollar figure — a $0.0000 total from 0 successes is not
  # the same as a "free" provider, so don't collapse it to "free".
  defp fmt_total(nil), do: "?"
  defp fmt_total(p) when is_float(p), do: "$" <> :erlang.float_to_binary(p, decimals: 4)

  defp min_or_nil([]), do: nil
  defp min_or_nil(xs), do: Enum.min(xs)

  defp avg_or_nil([]), do: nil
  defp avg_or_nil(xs), do: div(Enum.sum(xs), length(xs))

  defp median_or_nil([]), do: nil
  defp median_or_nil(xs), do: xs |> Enum.sort() |> Enum.at(div(length(xs), 2))

  # ── Stage scaffolds ──────────────────────────────────────────────────────────

  defp not_implemented(stage) do
    Mix.shell().info(
      "the #{stage} stage isn't wired into the benchmark yet — image is the current priority.\n" <>
        "structure to add it: declare candidates per provider, reuse timed/1 and print_table/1."
    )
  end

  # ── Args ─────────────────────────────────────────────────────────────────────

  defp parse_args(args) do
    {parsed, rest, _} =
      OptionParser.parse(args,
        strict: [
          providers: :string,
          modes: :string,
          runs: :integer,
          warmup: :boolean,
          prompt: :string,
          seed_image: :string
        ]
      )

    stage = List.first(rest) || "image"

    opts = [
      providers: parsed[:providers] && split_csv(parsed[:providers]),
      modes: parsed[:modes] && split_csv(parsed[:modes]),
      runs: parsed[:runs],
      warmup: parsed[:warmup],
      prompt: parsed[:prompt],
      seed_image: parsed[:seed_image]
    ]

    {stage, Enum.reject(opts, fn {_k, v} -> is_nil(v) end)}
  end

  defp split_csv(s), do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end
