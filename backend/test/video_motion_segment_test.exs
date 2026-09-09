defmodule Mix.Tasks.Sinestesia.VideoMotionSegmentTest do
  use ExUnit.Case, async: true

  # Real ffmpeg, real files. Each scene window becomes exactly ONE segment
  # — a retimed clip, or a held frame when its clip failed — normalized to
  # the canvas even when the provider returned other dimensions (the
  # Gemini lesson). No blending between scenes: continuity is the chain's
  # job, and a synthetic crossfade between independent clips reads as
  # cuts (founder-rejected on the first real Veo render).

  @canvas_w 1024
  @canvas_h 576

  setup do
    dir = Path.join(System.tmp_dir!(), "motion-seg-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    clip = Path.join(dir, "clip_00.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=2:size=1408x768:rate=30) ++ [clip],
        stderr_to_stdout: true
      )

    frame = Path.join(dir, "frame.jpg")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i color=c=teal:s=1280x720 -frames:v 1) ++ [frame],
        stderr_to_stdout: true
      )

    %{dir: dir, clip: clip, frame: frame}
  end

  test "a clip fills its window on the canvas, retimed", ctx do
    scene = %{index: 0, window_ms: 3_200, from: "unused", to: nil, prompt: "x"}

    seg =
      Mix.Tasks.Sinestesia.Video.motion_segment(scene, {:clip, ctx.clip}, @canvas_w, @canvas_h, ctx.dir)

    assert probe_dims(seg) == {@canvas_w, @canvas_h}
    assert_in_delta probe_duration_s(seg), 3.2, 0.15
  end

  test "a frozen frame (failed clip) holds its window, normalized to the canvas", ctx do
    # The frame is a RAW chain frame (1280x720, provider-sized) — the
    # segment must still come out on the canvas.
    scene = %{index: 1, window_ms: 2_000, from: "unused", to: nil, prompt: "x"}

    seg =
      Mix.Tasks.Sinestesia.Video.motion_segment(scene, {:still, ctx.frame}, @canvas_w, @canvas_h, ctx.dir)

    assert probe_dims(seg) == {@canvas_w, @canvas_h}
    assert_in_delta probe_duration_s(seg), 2.0, 0.15
  end

  defp probe_dims(path) do
    {out, 0} =
      System.cmd("ffprobe", [
        "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
        "-of", "csv=s=x:p=0", path
      ])

    [w, h] = out |> String.trim() |> String.split("x") |> Enum.map(&String.to_integer/1)
    {w, h}
  end

  defp probe_duration_s(path) do
    {out, 0} =
      System.cmd("ffprobe", [
        "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", path
      ])

    {sec, _} = Float.parse(String.trim(out))
    sec
  end
end
