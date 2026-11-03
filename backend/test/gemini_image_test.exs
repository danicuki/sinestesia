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
