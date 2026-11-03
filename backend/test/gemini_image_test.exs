defmodule Sinestesia.ImageGen.GeminiImageTest do
  use ExUnit.Case, async: true

  alias Sinestesia.ImageGen.GeminiImage

  # The failure line is read at a sound desk to decide "us or Google?" — so
  # it must say what was waited on, for how long, what was uploaded, and
  # what came back. No network: the outcome is handed in.
  @meta %{elapsed_ms: 10_004, limit_ms: 10_000, seed_bytes: 1_400_000, prompt_bytes: 120}

  test "a receive timeout: Google did not answer within the frame deadline, with the upload size" do
    line =
      GeminiImage.failure_line(
        "i2i",
        "gemini-3.1-flash-lite-image",
        {:transport, %Req.TransportError{reason: :timeout}},
        @meta
      )

    assert line =~ "[google-image] i2i gemini-3.1-flash-lite-image failed after 10004ms"
    assert line =~ "waiting for Google's answer, past the frame deadline (IMAGE_TIMEOUT_MS=10000)"
    assert line =~ "seed image 1.3 MB inline as base64"
    assert line =~ "not a rejection"
  end

  test "a connect timeout is told apart by how early it gave up" do
    line =
      GeminiImage.failure_line(
        "t2i",
        "m",
        {:transport, %Req.TransportError{reason: :timeout}},
        %{@meta | elapsed_ms: 5_003, seed_bytes: 0}
      )

    assert line =~ "connecting to Google"
    assert line =~ "no seed image"
  end

  test "an HTTP error carries Google's status, message and retry-after" do
    resp =
      Req.Response.new(
        status: 503,
        body: %{
          "error" => %{
            "code" => 503,
            "message" => "The model is overloaded. Please try again later.",
            "status" => "UNAVAILABLE"
          }
        }
      )
      |> Req.Response.put_header("retry-after", "7")

    line = GeminiImage.failure_line("i2i", "m", {:http, resp}, @meta)

    assert line =~
             ~s|HTTP 503 UNAVAILABLE "The model is overloaded. Please try again later." (retry-after 7)|
  end

  # Google's image latency has a long tail; the hedge is what keeps a slow
  # call from costing the line. The request is a fun, so no network here —
  # each fake answers after a delay and reports to the test that it ran.
  describe "hedged/4" do
    defp fake(delay_ms, reply) do
      test_pid = self()

      fn ->
        send(test_pid, {:request_started, delay_ms})
        Process.sleep(delay_ms)
        reply
      end
    end

    # One fun that answers differently on its first and second call.
    defp sequence(replies) do
      {:ok, agent} = Agent.start_link(fn -> replies end)
      test_pid = self()

      fn ->
        {delay, reply} = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
        send(test_pid, {:request_started, delay})
        Process.sleep(delay)
        reply
      end
    end

    @ok {:ok, %Req.Response{status: 200, body: %{"candidates" => []}}}
    @slow_ok {:ok, %Req.Response{status: 200, body: %{"candidates" => [], "slow" => true}}}
    @throttled {:ok, %Req.Response{status: 429, body: %{}}}

    test "a prompt answer never fires the hedge" do
      assert @ok == GeminiImage.hedged(fake(10, @ok), "i2i", "m", 200)
      assert_received {:request_started, 10}
      refute_received {:request_started, _}
    end

    test "a quiet first request gets a hedge, and the hedge's answer wins" do
      started = System.monotonic_time(:millisecond)
      assert @ok == GeminiImage.hedged(sequence([{2_000, @slow_ok}, {20, @ok}]), "i2i", "m", 100)
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed < 1_000, "the slow first request must not be waited for (took #{elapsed}ms)"
      assert_received {:request_started, 2_000}
      assert_received {:request_started, 20}
    end

    test "an error from the hedge does not sink a first request that then succeeds" do
      assert @slow_ok == GeminiImage.hedged(sequence([{300, @slow_ok}, {10, @throttled}]), "i2i", "m", 100)
    end

    test "when both fail, the answer is a failure, not a hang" do
      assert {:ok, %{status: 429}} = GeminiImage.hedged(sequence([{300, @throttled}, {10, @throttled}]), "i2i", "m", 100)
    end

    test "GOOGLE_HEDGE_MS=0 means one request, however slow" do
      assert @slow_ok == GeminiImage.hedged(fake(300, @slow_ok), "i2i", "m", 0)
      assert_received {:request_started, 300}
      refute_received {:request_started, _}
    end
  end

  # The i2i seed is Google's own ~1.2 MB PNG sent straight back; shrinking it
  # is what keeps i2i inside the frame deadline. Real ffmpeg, synthetic frame.
  describe "shrink_seed/3" do
    test "re-encodes a big PNG as a JPEG no wider than max_px, much smaller" do
      {png, w, h} = synthetic_png(1376, 768)
      {mime, b64} = GeminiImage.shrink_seed("image/png", Base.encode64(png), 1024)

      assert mime == "image/jpeg"
      jpeg = Base.decode64!(b64)
      assert byte_size(jpeg) < byte_size(png) / 3
      assert {1024, 572} == dims(jpeg)
      assert {w, h} == {1376, 768}
    end

    test "a frame already smaller than max_px is not upscaled" do
      {png, _, _} = synthetic_png(640, 360)
      {_, b64} = GeminiImage.shrink_seed("image/png", Base.encode64(png), 1024)
      assert {640, 360} == dims(Base.decode64!(b64))
    end

    test "max_px 0 sends the seed untouched" do
      assert {"image/png", "abc"} == GeminiImage.shrink_seed("image/png", "abc", 0)
    end

    test "bytes ffmpeg cannot read fall back to the original seed, never to no seed" do
      b64 = Base.encode64("not an image at all")
      assert {"image/png", ^b64} = GeminiImage.shrink_seed("image/png", b64, 1024)
    end
  end

  defp synthetic_png(w, h) do
    path = Path.join(System.tmp_dir!(), "gemini-seed-#{System.os_time(:nanosecond)}.png")

    {_, 0} =
      System.cmd("ffmpeg", ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=#{w}x#{h}:r=1,noise=alls=20:allf=t",
                            "-frames:v", "1", path], stderr_to_stdout: true)

    png = File.read!(path)
    File.rm!(path)
    {png, w, h}
  end

  defp dims(bytes) do
    path = Path.join(System.tmp_dir!(), "gemini-seed-#{System.os_time(:nanosecond)}.jpg")
    File.write!(path, bytes)

    {out, 0} =
      System.cmd("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                             "-of", "csv=p=0", path])

    File.rm!(path)
    [w, h] = out |> String.trim() |> String.split(",") |> Enum.map(&String.to_integer/1)
    {w, h}
  end

  test "any other transport error names itself and says no HTTP response came" do
    line =
      GeminiImage.failure_line(
        "i2i",
        "m",
        {:transport, %Req.TransportError{reason: :econnrefused}},
        @meta
      )

    assert line =~ "transport error %Req.TransportError{reason: :econnrefused} (no HTTP response)"
  end
end
