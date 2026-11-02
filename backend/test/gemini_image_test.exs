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
