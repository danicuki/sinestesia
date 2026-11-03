defmodule Sinestesia.ImageGen.GeminiImage do
  @moduledoc """
  Google image generation for `IMAGE_PROVIDER=google`: Gemini native image
  models via the `:generateContent` endpoint.

  This replaced the Imagen client (`:predict` endpoint) — Imagen 4 is
  deprecated (shutting down 2026-08-17) and had no image-to-image. Gemini image
  models take a multimodal `contents` payload and return image bytes inline,
  which means the same call does both:

    * text-to-image  — `generate(prompt)`
    * image-to-image — `generate(prompt, image_url: data_or_http_url)` (the seed
      is sent as an inline image part alongside the prompt)

  Returns `data:image/...;base64,...`. Model id comes from `opts[:model]`, then
  the `GOOGLE_IMAGE_MODEL` env var, then the default. A leading `models/`
  prefix is stripped. The model must be a Gemini `*-image` model — pointing
  this at an Imagen id fails with a 404, since Imagen only ever lived on
  `:predict`.

  ## When a frame fails

  The frame deadline is not here: `Sinestesia.ImageGen.timeout_ms/0`
  (`IMAGE_TIMEOUT_MS`, 10 s at most) abandons the whole frame, this request
  included, and logs `[image_gen] frame abandoned … google <model> i2i, seed
  image 1.4 MB uploaded inline`. No HTTP status came back by then: Google took
  longer than the deadline to answer, or the upload did — an i2i call carries
  the previous frame inline as base64, 1-2 MB per request, which on a venue's
  uplink is not free. That is not a rejection. A rejection is an HTTP 4xx/5xx
  with Google's own `status`/`message`, and THAT is logged here, where the
  request is known: route and model, elapsed, payload, Google's message and
  retry-after. So is a connect timeout (5 s, no TCP/TLS at all: the network
  on our side) and any other transport error that comes back before the
  deadline.
  """
  require Logger

  @default_model "gemini-3.1-flash-lite-image"
  # Half the frame budget: a hang this early is the network, not the model,
  # and it leaves time for the t2i fallback.
  @connect_timeout_ms 5_000

  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, opts \\ []) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    model =
      (opts[:model] || System.get_env("GOOGLE_IMAGE_MODEL") || @default_model)
      |> normalize_model()

    route = if opts[:image_url] in [nil, ""], do: "t2i", else: "i2i"
    Sinestesia.ImageGen.note_route(route, model, nil)

    case Keyword.get(cfg, :google_api_key) do
      nil ->
        {:error, :no_google_key}

      key ->
        with {:ok, parts, seed_bytes} <- build_parts(prompt, opts[:image_url]) do
          # Noted again with the upload size, so the deadline's log line can
          # say how much was on the wire when nothing came back.
          Sinestesia.ImageGen.note_route(route, model, nil, seed_bytes: seed_bytes)

          url =
            "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

          body = %{
            contents: [%{parts: parts}],
            generationConfig: %{responseModalities: ["IMAGE"]}
          }

          started = System.monotonic_time(:millisecond)
          result = hedged(fn -> post(url, body) end, route, model, hedge_ms())

          meta = %{
            elapsed_ms: System.monotonic_time(:millisecond) - started,
            limit_ms: Sinestesia.ImageGen.timeout_ms(),
            seed_bytes: seed_bytes,
            prompt_bytes: byte_size(prompt)
          }

          case result do
            {:ok, %{status: 200, body: resp}} ->
              Logger.debug(
                "[google-image] #{route} #{model} answered in #{meta.elapsed_ms}ms#{usage_tag(resp)}"
              )

              extract_image(resp)

            {:ok, resp} ->
              Logger.warning(failure_line(route, model, {:http, resp}, meta))
              {:error, {:bad_status, resp.status, resp.body}}

            {:error, reason} ->
              Logger.warning(failure_line(route, model, {:transport, reason}, meta))
              {:error, reason}
          end
        end
    end
  end

  # ── hedging ───────────────────────────────────────────────────────────────
  # Google's image latency has a long tail: on the stage, 2026-11-03, most
  # i2i calls answered in 3-4 s and some never answered inside the 10 s
  # frame deadline, seed already down to 89 KB. The classic cut for a tail
  # like that is a hedged request: when the first call has gone quiet for
  # GOOGLE_HEDGE_MS, fire an identical second one and take whichever answers
  # first. It costs one extra generation only on the slow tail; a frame that
  # misses the deadline costs the line of the song.
  @default_hedge_ms 5_000

  defp hedge_ms do
    case Integer.parse(System.get_env("GOOGLE_HEDGE_MS", "#{@default_hedge_ms}")) do
      {ms, _} when ms >= 0 -> ms
      _ -> @default_hedge_ms
    end
  end

  defp post(url, body) do
    Req.post(url,
      json: body,
      receive_timeout: Sinestesia.ImageGen.backstop_timeout_ms(),
      connect_options: [timeout: @connect_timeout_ms],
      retry: false
    )
  end

  @doc false
  # `request` is a zero-arity fun returning what Req.post returns, so the
  # race is testable without a network. No hedge when it is off, or when it
  # could not fire before the frame deadline anyway (the outer
  # within_deadline kills us, and the linked request tasks with us).
  def hedged(request, _route, _model, hedge_ms) when hedge_ms <= 0 or hedge_ms >= 9_000,
    do: request.()

  def hedged(request, route, model, hedge_ms) do
    first = Task.async(request)

    case Task.yield(first, hedge_ms) do
      {:ok, reply} ->
        reply

      {:exit, reason} ->
        {:error, {:request_task_exit, reason}}

      nil ->
        Logger.info(
          "[google-image] #{route} #{model}: no answer after #{hedge_ms}ms — " <>
            "hedging with a second identical request, first one to answer wins"
        )

        second = Task.async(request)
        race(first, second, hedge_ms)
    end
  end

  # First GOOD answer wins; an error from one side waits for the other, so a
  # 429 on the hedge cannot sink a first request that was about to succeed.
  defp race(first, second, hedge_ms) do
    deadline = Sinestesia.ImageGen.backstop_timeout_ms()
    started = System.monotonic_time(:millisecond)

    receive do
      {ref, reply} when ref == first.ref or ref == second.ref ->
        Process.demonitor(ref, [:flush])
        {winner, loser} = if ref == first.ref, do: {"first", second}, else: {"hedge", first}

        case reply do
          {:ok, %{status: 200}} ->
            Logger.info(
              "[google-image] #{winner} request answered #{System.monotonic_time(:millisecond) - started}ms " <>
                "after the hedge fired (#{hedge_ms}ms in); dropping the other"
            )

            Task.shutdown(loser, :brutal_kill)
            reply

          _bad ->
            case Task.yield(loser, deadline) || Task.shutdown(loser, :brutal_kill) do
              {:ok, other} -> other
              _ -> reply
            end
        end

      {:DOWN, ref, _, _, reason} when ref == first.ref or ref == second.ref ->
        other = if ref == first.ref, do: second, else: first

        case Task.yield(other, deadline) || Task.shutdown(other, :brutal_kill) do
          {:ok, reply} -> reply
          _ -> {:error, {:request_task_exit, reason}}
        end
    after
      deadline ->
        Task.shutdown(first, :brutal_kill)
        Task.shutdown(second, :brutal_kill)
        {:error, %Req.TransportError{reason: :timeout}}
    end
  end

  # What Google says it spent — a thinking image model would show up here
  # as thoughtsTokenCount, and that would explain a tail no upload can.
  defp usage_tag(%{"usageMetadata" => usage} = resp) do
    thoughts = Map.get(usage, "thoughtsTokenCount")
    out = Map.get(usage, "candidatesTokenCount")
    version = Map.get(resp, "modelVersion")

    " (" <>
      Enum.join(
        Enum.reject(
          [
            version && "model #{version}",
            out && "#{out} output tokens",
            thoughts && "#{thoughts} THINKING tokens"
          ],
          &is_nil/1
        ),
        ", "
      ) <> ")"
  end

  defp usage_tag(_resp), do: ""

  @doc false
  # One line that says what was being waited on and what came back — for the
  # person at the sound desk deciding whether the problem is here or at
  # Google. `outcome` is `{:transport, reason}` (no HTTP response at all) or
  # `{:http, %Req.Response{}}` (Google answered, with an error).
  def failure_line(route, model, outcome, meta) do
    head = "[google-image] #{route} #{model} failed after #{meta.elapsed_ms}ms"

    payload =
      "payload #{human_bytes(meta.prompt_bytes + meta.seed_bytes)} (" <>
        if(meta.seed_bytes > 0,
          do: "seed image #{human_bytes(meta.seed_bytes)} inline as base64)",
          else: "no seed image)"
        )

    case outcome do
      {:transport, %Req.TransportError{reason: :timeout}} ->
        where =
          if meta.elapsed_ms >= meta.limit_ms do
            "waiting for Google's answer, past the frame deadline (IMAGE_TIMEOUT_MS=#{meta.limit_ms})"
          else
            "connecting to Google (no TCP/TLS within #{@connect_timeout_ms}ms — the network on our side)"
          end

        "#{head}: timed out #{where}; #{payload}. No HTTP status came back, so this is " <>
          "not a rejection: Google took longer than our limit to answer, or the upload did."

      {:transport, reason} ->
        "#{head}: transport error #{inspect(reason)} (no HTTP response); #{payload}"

      {:http, resp} ->
        "#{head}: HTTP #{resp.status}#{google_error(resp.body)}#{retry_after(resp)}; #{payload}"
    end
  end

  # Google's error envelope: {"error": {"code": 503, "message": "...", "status": "UNAVAILABLE"}}
  defp google_error(%{"error" => %{} = err}) do
    status = err["status"]
    message = err["message"]

    [status, message && ~s("#{String.slice(message, 0, 300)}")]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", & &1)
    |> then(&if(&1 == "", do: "", else: " " <> &1))
  end

  defp google_error(body) when is_binary(body) and body != "", do: " " <> String.slice(body, 0, 300)
  defp google_error(_), do: ""

  defp retry_after(resp) do
    case Req.Response.get_header(resp, "retry-after") do
      [v | _] -> " (retry-after #{v})"
      _ -> ""
    end
  end

  defp human_bytes(b), do: Sinestesia.ImageGen.human_bytes(b)

  defp normalize_model(model), do: String.replace_prefix(model, "models/", "")

  # text-only → one text part. i2i → text part + inline seed image part. The
  # third element is the seed's size on the wire (its base64), for the log.
  defp build_parts(prompt, nil), do: {:ok, [%{text: prompt}], 0}
  defp build_parts(prompt, ""), do: {:ok, [%{text: prompt}], 0}

  defp build_parts(prompt, image_url) do
    with {:ok, mime, b64} <- inline_image(image_url) do
      {mime, b64} = shrink_seed(mime, b64, seed_max_px())
      {:ok, [%{text: prompt}, %{inlineData: %{mimeType: mime, data: b64}}], byte_size(b64)}
    end
  end

  # ── seed size ─────────────────────────────────────────────────────────────
  # The seed of an i2i call is Google's OWN previous frame: a 1376×768 PNG of
  # ~1.2 MB, sent straight back as base64 (~1.6 MB on the wire) on every
  # line of the song. Measured 2026-11-03: t2i answered in ~4 s while i2i
  # with that seed took 6 s to 20 s+ and blew the frame deadline. Re-encoding
  # it as a 1024 px JPEG costs ~160 ms of ffmpeg and cuts the upload ~6×;
  # the model is drawing the next scene over it, not inspecting pixels.
  @default_seed_max_px 1024

  defp seed_max_px do
    case Integer.parse(System.get_env("GOOGLE_SEED_MAX_PX", "#{@default_seed_max_px}")) do
      {px, _} when px >= 0 -> px
      _ -> @default_seed_max_px
    end
  end

  @doc false
  # `max_px` 0 sends the seed as it came. Anything that goes wrong in the
  # shrink (no ffmpeg, odd bytes) falls back to the original bytes: a bigger
  # upload is a slower frame, a lost seed is a lost frame.
  def shrink_seed(mime, b64, 0), do: {mime, b64}

  def shrink_seed(mime, b64, max_px) do
    with {:ok, bytes} <- Base.decode64(b64),
         {:ok, jpeg} <- transcode(bytes, max_px) do
      Logger.debug(
        "[google-image] seed #{human_bytes(byte_size(bytes))} #{mime} → " <>
          "#{human_bytes(byte_size(jpeg))} jpeg ≤#{max_px}px for the upload"
      )

      {"image/jpeg", Base.encode64(jpeg)}
    else
      _ -> {mime, b64}
    end
  end

  # System.cmd has no stdin, so the seed goes through two temp files; ffmpeg
  # is the one image tool this codebase already depends on everywhere.
  defp transcode(bytes, max_px) do
    tag = "#{System.os_time(:nanosecond)}-#{:erlang.unique_integer([:positive])}"
    src = Path.join(System.tmp_dir!(), "sinestesia-seed-#{tag}.in")
    dst = Path.join(System.tmp_dir!(), "sinestesia-seed-#{tag}.jpg")

    try do
      File.write!(src, bytes)

      args = [
        "-v", "error", "-y", "-i", src,
        "-vf", "scale='min(#{max_px},iw)':-2", "-q:v", "4", "-f", "mjpeg", dst
      ]

      case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
        {_, 0} -> File.read(dst)
        {out, status} -> {:error, {:ffmpeg, status, String.trim(out)}}
      end
    rescue
      e -> {:error, e}
    after
      File.rm(src)
      File.rm(dst)
    end
  end

  defp inline_image("data:image/" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [meta, b64] ->
        mime = "image/" <> (meta |> String.split(";") |> List.first())
        {:ok, mime, b64}

      _ ->
        {:error, :bad_data_url}
    end
  end

  defp inline_image("http" <> _ = url) do
    case Req.get(url,
           receive_timeout: Sinestesia.ImageGen.backstop_timeout_ms(),
           retry: false,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: bin}} ->
        mime = if String.contains?(url, ".png"), do: "image/png", else: "image/jpeg"
        {:ok, mime, Base.encode64(bin)}

      {:ok, %{status: status}} ->
        {:error, {:input_fetch, status}}

      {:error, reason} ->
        {:error, {:input_fetch, reason}}
    end
  end

  defp inline_image(other), do: {:error, {:bad_input_url, other}}

  defp extract_image(%{"candidates" => candidates} = body) do
    candidate = List.first(candidates, %{})
    parts = get_in(candidate, ["content", "parts"]) || []

    case Enum.find(parts, &match?(%{"inlineData" => %{"data" => _}}, &1)) do
      %{"inlineData" => %{"data" => b64} = data} ->
        mime = Map.get(data, "mimeType", "image/png")
        {:ok, "data:#{mime};base64," <> b64}

      _ ->
        # A 200 with no image is a REFUSAL, and the reason is never in the
        # parts (they come back empty) — it's in the candidate's
        # finishReason (IMAGE_SAFETY, PROHIBITED_CONTENT, RECITATION —
        # trademarked characters land here: "spider-man" fails where
        # "spider-suit hero" passes) and in promptFeedback. Surface both:
        # someone at a sound desk needs to know WHICH word poisoned the
        # prompt, not that a list was empty.
        {:error,
         {:no_image_in_response,
          %{
            finish_reason: Map.get(candidate, "finishReason"),
            block_reason: get_in(body, ["promptFeedback", "blockReason"]),
            refusal_text:
              parts |> Enum.find_value(&Map.get(&1, "text")) |> then(&(&1 && String.slice(&1, 0, 200)))
          }}}
    end
  end

  defp extract_image(other), do: {:error, {:unexpected_body, other}}
end
