defmodule Sinestesia.VideoGen.GeminiVeoTest do
  # async: false — swaps the app-wide config to inject a fake Google key.
  use ExUnit.Case, async: false

  alias Sinestesia.VideoGen.GeminiVeo

  # The predictLongRunning conversation as the Gemini API speaks it (submit
  # → operation pending → operation done → file download), against a local
  # stub. The first poll answers pending so the loop itself is exercised.

  @clip_bytes "definitely-a-veo-clip"

  setup do
    cfg = Application.fetch_env!(:sinestesia, :config)
    Application.put_env(:sinestesia, :config, Keyword.put(cfg, :google_api_key, "test-google-key"))
    on_exit(fn -> Application.put_env(:sinestesia, :config, cfg) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    parent = self()
    spawn_link(fn -> accept_loop(listener, parent, port, %{polls: 0}) end)

    dir = Path.join(System.tmp_dir!(), "gemini-veo-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{port: port, dir: dir}
  end

  test "submit → poll → download, keyframes as inlineData", %{port: port, dir: dir} do
    from = Path.join(dir, "from.jpg")
    to = Path.join(dir, "to.png")
    File.write!(from, "opening-frame")
    File.write!(to, "final-frame")

    base = "http://127.0.0.1:#{port}"

    assert {:ok, op} =
             GeminiVeo.submit("gentle drift toward the window", from,
               to: to,
               duration: 6,
               resolution: "720p",
               aspect_ratio: "16:9",
               model: "veo-lite",
               base_url: base
             )

    assert op == "models/veo-3.1-lite-generate-preview/operations/op1"

    dest = Path.join(dir, "clip.mp4")
    assert {:ok, ^dest} = GeminiVeo.await(op, dest, base_url: base, poll_ms: 50)
    assert File.read!(dest) == @clip_bytes

    assert_receive {:req, :POST, "/models/veo-3.1-lite-generate-preview:predictLongRunning",
                    headers, body}

    assert {"x-goog-api-key", "test-google-key"} in headers

    decoded = Jason.decode!(body)
    [instance] = decoded["instances"]
    assert instance["prompt"] == "gentle drift toward the window"
    assert instance["image"]["inlineData"]["mimeType"] == "image/jpeg"
    assert instance["image"]["inlineData"]["data"] == Base.encode64("opening-frame")
    assert instance["lastFrame"]["inlineData"]["mimeType"] == "image/png"
    assert instance["lastFrame"]["inlineData"]["data"] == Base.encode64("final-frame")

    assert decoded["parameters"] == %{
             "aspectRatio" => "16:9",
             "durationSeconds" => 6,
             "resolution" => "720p"
           }
  end

  test "a done operation with no video is a NAMED refusal", %{port: port, dir: dir} do
    base = "http://127.0.0.1:#{port}"
    dest = Path.join(dir, "never.mp4")

    assert {:error, {:no_video, details}} =
             GeminiVeo.await("models/x/operations/filtered", dest, base_url: base, poll_ms: 50)

    assert details.filtered_count == 1
    assert details.filtered_reasons == ["Responsible AI practices"]
  end

  test "clamp_duration snaps to 4|6|8, ties preferring the longer clip" do
    assert GeminiVeo.clamp_duration(1.0) == 4
    assert GeminiVeo.clamp_duration(5.0) == 6
    assert GeminiVeo.clamp_duration(7.0) == 8
    assert GeminiVeo.clamp_duration(6.4) == 6
    assert GeminiVeo.clamp_duration(40.0) == 8
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
    {payload, ctype, state} = respond(method, path, port, state)

    :gen_tcp.send(
      sock,
      "HTTP/1.1 200 OK\r\ncontent-type: #{ctype}\r\n" <>
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

  defp respond(:POST, "/models/veo-3.1-lite-generate-preview:predictLongRunning", _port, state),
    do: {~s({"name":"models/veo-3.1-lite-generate-preview/operations/op1"}), "application/json", state}

  defp respond(:GET, "/models/veo-3.1-lite-generate-preview/operations/op1", port, %{polls: polls} = state) do
    if polls == 0 do
      {~s({"name":"op1"}), "application/json", %{state | polls: 1}}
    else
      body =
        ~s({"done":true,"response":{"generateVideoResponse":{"generatedSamples":[) <>
          ~s({"video":{"uri":"http://127.0.0.1:#{port}/files/v1:download"}}]}}})

      {body, "application/json", state}
    end
  end

  defp respond(:GET, "/models/x/operations/filtered", _port, state) do
    body =
      ~s({"done":true,"response":{"generateVideoResponse":) <>
        ~s({"raiMediaFilteredCount":1,"raiMediaFilteredReasons":["Responsible AI practices"]}}})

    {body, "application/json", state}
  end

  defp respond(:GET, "/files/v1:download", _port, state),
    do: {@clip_bytes, "video/mp4", state}
end
