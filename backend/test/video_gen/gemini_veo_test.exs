defmodule Sinestesia.VideoGen.GeminiVeoTest do
  # async: false — swaps the app-wide config and the persisted image-shape.
  use ExUnit.Case, async: false

  alias Sinestesia.VideoGen.GeminiVeo

  # The predictLongRunning conversation against a local stub. Google's own
  # surfaces disagree on the image field's spelling (docs say inlineData,
  # the live model rejected it, the SDK sends imageBytes), so submit
  # NEGOTIATES: these tests pin the default shape, the fallback walk on
  # 400s, and that the winner is remembered for subsequent clips.

  @clip_bytes "definitely-a-veo-clip"
  @shape_key {Sinestesia.VideoGen.GeminiVeo, :image_shape}

  setup context do
    cfg = Application.fetch_env!(:sinestesia, :config)
    Application.put_env(:sinestesia, :config, Keyword.put(cfg, :google_api_key, "test-google-key"))
    :persistent_term.erase(@shape_key)

    on_exit(fn ->
      Application.put_env(:sinestesia, :config, cfg)
      :persistent_term.erase(@shape_key)
    end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    parent = self()
    mode = Map.get(context, :mode, :accept)
    spawn_link(fn -> accept_loop(listener, parent, port, %{polls: 0, mode: mode}) end)

    dir = Path.join(System.tmp_dir!(), "gemini-veo-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    from = Path.join(dir, "from.jpg")
    to = Path.join(dir, "to.png")
    File.write!(from, "opening-frame")
    File.write!(to, "final-frame")

    %{port: port, dir: dir, from: from, to: to, base: "http://127.0.0.1:#{port}"}
  end

  test "submit → poll → download; SDK shape by default, keyframes force 8s", ctx do
    assert {:ok, op} =
             GeminiVeo.submit("gentle drift toward the window", ctx.from,
               to: ctx.to,
               duration: 6,
               resolution: "720p",
               aspect_ratio: "16:9",
               model: "veo-lite",
               base_url: ctx.base
             )

    assert op == "models/veo-3.1-lite-generate-preview/operations/op1"

    dest = Path.join(ctx.dir, "clip.mp4")
    assert {:ok, ^dest} = GeminiVeo.await(op, dest, base_url: ctx.base, poll_ms: 50)
    assert File.read!(dest) == @clip_bytes

    assert_receive {:req, :POST, "/models/veo-3.1-lite-generate-preview:predictLongRunning",
                    headers, body}

    assert {"x-goog-api-key", "test-google-key"} in headers

    decoded = Jason.decode!(body)
    [instance] = decoded["instances"]
    assert instance["prompt"] == "gentle drift toward the window"
    assert instance["image"]["bytesBase64Encoded"] == Base.encode64("opening-frame")
    assert instance["image"]["mimeType"] == "image/jpeg"
    assert instance["lastFrame"]["bytesBase64Encoded"] == Base.encode64("final-frame")
    assert instance["lastFrame"]["mimeType"] == "image/png"

    # duration: 6 was REQUESTED, but a keyframed clip bills 8s — the API
    # rejects interpolation at any other length, and the stub enforces it.
    assert decoded["parameters"] == %{
             "aspectRatio" => "16:9",
             "durationSeconds" => 8,
             "resolution" => "720p"
           }
  end

  @tag mode: :only_image_bytes
  test "a rejected shape walks the alternatives, and the winner sticks", ctx do
    assert {:ok, _op} =
             GeminiVeo.submit("drift", ctx.from, model: "veo-fast", base_url: ctx.base)

    # The negotiation: SDK spelling rejected, docs spelling rejected, the
    # third accepted.
    assert_receive {:req, :POST, _, _, b1}

    assert Jason.decode!(b1)["instances"]
           |> hd()
           |> Map.fetch!("image")
           |> Map.has_key?("bytesBase64Encoded")

    assert_receive {:req, :POST, _, _, b2}
    assert Jason.decode!(b2)["instances"] |> hd() |> Map.fetch!("image") |> Map.has_key?("inlineData")
    assert_receive {:req, :POST, _, _, b3}
    assert Jason.decode!(b3)["instances"] |> hd() |> Map.fetch!("image") |> Map.has_key?("imageBytes")

    # The next clip skips straight to the remembered winner: ONE post.
    assert {:ok, _op} =
             GeminiVeo.submit("drift again", ctx.from, model: "veo-fast", base_url: ctx.base)

    assert_receive {:req, :POST, _, _, b4}
    assert Jason.decode!(b4)["instances"] |> hd() |> Map.fetch!("image") |> Map.has_key?("imageBytes")

    refute_receive {:req, :POST, _, _, _}, 100
  end

  test "a drift clip (no end frame) keeps its requested duration", ctx do
    assert {:ok, _op} =
             GeminiVeo.submit("drift", ctx.from,
               duration: 4,
               model: "veo-fast",
               base_url: ctx.base
             )

    assert_receive {:req, :POST, _, _, body}
    decoded = Jason.decode!(body)
    refute decoded["instances"] |> hd() |> Map.has_key?("lastFrame")
    assert decoded["parameters"]["durationSeconds"] == 4
  end

  test "a done operation with no video is a NAMED refusal", ctx do
    dest = Path.join(ctx.dir, "never.mp4")

    assert {:error, {:no_video, details}} =
             GeminiVeo.await("models/x/operations/filtered", dest, base_url: ctx.base, poll_ms: 50)

    assert details.filtered_count == 1
    assert details.filtered_reasons == ["Responsible AI practices"]
  end

  test "billable_duration: drift snaps to 4|6|8 (ties longer); keyframed is always 8" do
    assert GeminiVeo.billable_duration(1.0, false) == 4
    assert GeminiVeo.billable_duration(5.0, false) == 6
    assert GeminiVeo.billable_duration(7.0, false) == 8
    assert GeminiVeo.billable_duration(6.4, false) == 6
    assert GeminiVeo.billable_duration(40.0, false) == 8
    assert GeminiVeo.billable_duration(4.0, true) == 8
    assert GeminiVeo.billable_duration(40.0, true) == 8
  end

  # ── stub Gemini API ───────────────────────────────────────────────────────

  defp accept_loop(listener, parent, port, state) do
    {:ok, sock} = :gen_tcp.accept(listener)
    {:ok, {:http_request, method, {:abs_path, path}, _}} = :gen_tcp.recv(sock, 0, 10_000)
    {headers, clen} = read_headers(sock, [], 0)

    body =
      if clen > 0 do
        :ok = :inet.setopts(sock, packet: :raw)
        read_exact(sock, clen, "")
      else
        ""
      end

    send(parent, {:req, method, path, headers, body})
    {status, payload, ctype, state} = respond(method, path, body, port, state)

    :gen_tcp.send(
      sock,
      "HTTP/1.1 #{status} X\r\ncontent-type: #{ctype}\r\n" <>
        "content-length: #{byte_size(payload)}\r\nconnection: close\r\n\r\n" <> payload
    )

    :gen_tcp.close(sock)
    accept_loop(listener, parent, port, state)
  end

  defp read_headers(sock, acc, clen) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        key = name |> to_string() |> String.downcase()
        clen = if key == "content-length", do: String.to_integer(to_string(value)), else: clen
        read_headers(sock, [{key, to_string(value)} | acc], clen)

      {:ok, :http_eoh} ->
        {Enum.reverse(acc), clen}
    end
  end

  defp read_exact(_sock, 0, acc), do: acc

  defp read_exact(sock, n, acc) do
    {:ok, chunk} = :gen_tcp.recv(sock, min(n, 65_536), 10_000)
    read_exact(sock, n - byte_size(chunk), acc <> chunk)
  end

  defp respond(:POST, "/models/" <> _ = path, body, _port, state) do
    model = path |> String.split("/models/") |> List.last() |> String.split(":") |> hd()
    decoded = Jason.decode!(body)
    instance = hd(decoded["instances"])
    image = Map.fetch!(instance, "image")

    # The real API's rule, hit live 2026-08-29: interpolation (lastFrame)
    # only at durationSeconds 8.
    if Map.has_key?(instance, "lastFrame") and decoded["parameters"]["durationSeconds"] != 8 do
      throw(:use_case)
    end

    accepted? =
      case state.mode do
        :accept -> true
        :only_image_bytes -> Map.has_key?(image, "imageBytes")
      end

    if accepted? do
      {200, ~s({"name":"models/#{model}/operations/op1"}), "application/json", state}
    else
      [shape] = Map.keys(image) -- ["mimeType"]

      {400,
       ~s({"error":{"code":400,"message":"`#{shape}` isn't supported by this model.","status":"INVALID_ARGUMENT"}}),
       "application/json", state}
    end
  catch
    :use_case ->
      {400,
       ~s({"error":{"code":400,"message":"Your use case is currently not supported.","status":"INVALID_ARGUMENT"}}),
       "application/json", state}
  end

  defp respond(:GET, "/models/x/operations/filtered", _body, _port, state) do
    body =
      ~s({"done":true,"response":{"generateVideoResponse":) <>
        ~s({"raiMediaFilteredCount":1,"raiMediaFilteredReasons":["Responsible AI practices"]}}})

    {200, body, "application/json", state}
  end

  defp respond(:GET, path, _body, port, %{polls: polls} = state) do
    cond do
      String.contains?(path, "/operations/") and polls == 0 ->
        {200, ~s({"name":"op1"}), "application/json", %{state | polls: 1}}

      String.contains?(path, "/operations/") ->
        body =
          ~s({"done":true,"response":{"generateVideoResponse":{"generatedSamples":[) <>
            ~s({"video":{"uri":"http://127.0.0.1:#{port}/files/v1:download"}}]}}})

        {200, body, "application/json", state}

      path == "/files/v1:download" ->
        {200, @clip_bytes, "video/mp4", state}
    end
  end
end
