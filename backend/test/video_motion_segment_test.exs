defmodule Mix.Tasks.Sinestesia.VideoMotionSegmentTest do
  use ExUnit.Case, async: true

  # Real ffmpeg, real files: a generated clip must be retimed to fill its
  # scene window EXACTLY (its final frame is the next scene's reveal), and a
  # failed clip's window must degrade to the held still — both on the canvas
  # even when the provider returned other dimensions (the Gemini lesson).

  @canvas_w 1024
  @canvas_h 576

  setup do
    dir = Path.join(System.tmp_dir!(), "motion-seg-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a clip is retimed onto the window and the canvas", %{dir: dir} do
    clip = Path.join(dir, "clip_00.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i testsrc=duration=2:size=1408x768:rate=30) ++ [clip],
        stderr_to_stdout: true
      )

    scene = %{index: 0, window_ms: 3_200, from: "unused", to: nil, prompt: "x"}

    seg =
      Mix.Tasks.Sinestesia.Video.motion_segment(scene, clip, %{}, @canvas_w, @canvas_h, dir)

    assert probe_dims(seg) == {@canvas_w, @canvas_h}
    assert_in_delta probe_duration_s(seg), 3.2, 0.15
  end

  test "a failed clip degrades to the held still for the window", %{dir: dir} do
    still = Path.join(dir, "norm_still.jpg")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i color=c=teal:s=#{@canvas_w}x#{@canvas_h} -frames:v 1) ++ [still],
        stderr_to_stdout: true
      )

    scene = %{index: 1, window_ms: 2_000, from: "anchor.jpg", to: nil, prompt: "x"}

    seg =
      Mix.Tasks.Sinestesia.Video.motion_segment(
        scene,
        nil,
        %{"anchor.jpg" => still},
        @canvas_w,
        @canvas_h,
        dir
      )

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
