defmodule Sinestesia.VideoGen.FalMinimaxTest do
  # async: false — swaps the app-wide config to inject a fake fal key.
  use ExUnit.Case, async: false

  alias Sinestesia.VideoGen.FalMinimax

  # The full queue conversation as fal actually speaks it (submit → status
  # while queued → status completed → result → CDN download), served by a
  # local stub so the paid API is never touched. The one deliberate delay:
  # the first status poll answers IN_QUEUE, so the polling loop itself is
  # exercised, not just the happy path.

  @clip_bytes "definitely-a-generated-clip"

  setup do
    cfg = Application.fetch_env!(:sinestesia, :config)
    Application.put_env(:sinestesia, :config, Keyword.put(cfg, :fal_api_key, "test-key"))
    on_exit(fn -> Application.put_env(:sinestesia, :config, cfg) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    parent = self()
    spawn_link(fn -> accept_loop(listener, parent, port, %{status_calls: 0}) end)

    dir = Path.join(System.tmp_dir!(), "fal-minimax-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{port: port, dir: dir}
  end

  test "submit → poll → download, with keyframes as data URIs", %{port: port, dir: dir} do
    from = Path.join(dir, "from.jpg")
    to = Path.join(dir, "to.jpg")
    File.write!(from, "opening-frame")
    File.write!(to, "final-frame")

    assert {:ok, request_url} =
             FalMinimax.submit("gentle drift toward the window", from,
               to: to,
               duration: 7,
               resolution: "768P",
               base_url: "http://127.0.0.1:#{port}"
             )

    assert request_url == "http://127.0.0.1:#{port}/minimax/h3-max/image-to-video/requests/r1"

    dest = Path.join(dir, "clip.mp4")
    assert {:ok, ^dest} = FalMinimax.await(request_url, dest)
    assert File.read!(dest) == @clip_bytes

    assert_receive {:req, :POST, "/minimax/h3-max/image-to-video", headers, body}
    assert {"authorization", "Key test-key"} in headers

    decoded = Jason.decode!(body)
    assert decoded["prompt"] == "gentle drift toward the window"
    assert decoded["duration"] == 7
    assert decoded["resolution"] == "768P"
    assert decoded["image_url"] == "data:image/jpeg;base64," <> Base.encode64("opening-frame")
    assert decoded["end_image_url"] == "data:image/jpeg;base64," <> Base.encode64("final-frame")
  end

  test "clamp_duration maps scene windows onto the API's billable range" do
    assert FalMinimax.clamp_duration(0.4) == 5
    assert FalMinimax.clamp_duration(6.7) == 7
    assert FalMinimax.clamp_duration(31.0) == 15
  end

  # ── stub fal queue ────────────────────────────────────────────────────────

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
    {payload, state} = respond(method, path, port, state)

    :gen_tcp.send(
      sock,
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
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

  defp respond(:POST, "/minimax/h3-max/image-to-video", _port, state),
    do: {~s({"request_id":"r1"}), state}

  defp respond(:GET, "/minimax/h3-max/image-to-video/requests/r1/status", _port, %{status_calls: 0} = state),
    do: {~s({"status":"IN_QUEUE","queue_position":0}), %{state | status_calls: 1}}

  defp respond(:GET, "/minimax/h3-max/image-to-video/requests/r1/status", _port, state),
    do: {~s({"status":"COMPLETED"}), state}

  defp respond(:GET, "/minimax/h3-max/image-to-video/requests/r1", port, state),
    do: {~s({"video":{"url":"http://127.0.0.1:#{port}/video.mp4"}}), state}

  defp respond(:GET, "/video.mp4", _port, state), do: {@clip_bytes, state}
end
