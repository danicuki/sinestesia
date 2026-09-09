defmodule Mix.Tasks.Sinestesia.VideoMotionSegmentTest do
  use ExUnit.Case, async: true

  # Real ffmpeg, real files. A scene window becomes a LIST of segments that
  # must fill it exactly on the canvas: a keyframed clip fills it alone (it
  # already ends on the next anchor); a drift clip reserves the window's
  # tail for the blend into the next anchor; a failed clip degrades to the
  # held still — all on the canvas even when the provider returned other
  # dimensions (the Gemini lesson).

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

    anchor = Path.join(dir, "norm_anchor.jpg")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i color=c=teal:s=#{@canvas_w}x#{@canvas_h} -frames:v 1) ++ [anchor],
        stderr_to_stdout: true
      )

    %{dir: dir, clip: clip, anchor: anchor}
  end

  test "keyframed: one segment, retimed onto the window and the canvas", ctx do
    scene = %{index: 0, window_ms: 3_200, from: "unused", to: "next.jpg", prompt: "x"}

    [seg] =
      Mix.Tasks.Sinestesia.Video.motion_segment(scene, ctx.clip, %{}, @canvas_w, @canvas_h, ctx.dir, 1_500, false)

    assert probe_dims(seg) == {@canvas_w, @canvas_h}
    assert_in_delta probe_duration_s(seg), 3.2, 0.15
  end

  test "drift: the window's tail becomes the blend into the next anchor", ctx do
    scene = %{index: 0, window_ms: 3_200, from: "unused", to: "next.jpg", prompt: "x"}
    normed = %{"next.jpg" => ctx.anchor}

    [body, tail] =
      Mix.Tasks.Sinestesia.Video.motion_segment(scene, ctx.clip, normed, @canvas_w, @canvas_h, ctx.dir, 1_500, true)

    # blend = min(1.5s, window/3 ≈ 1.07s) — the rest is the living clip.
    assert_in_delta probe_duration_s(body), 3.2 - 1.0667, 0.15
    assert_in_delta probe_duration_s(tail), 1.0667, 0.2
    assert probe_dims(body) == {@canvas_w, @canvas_h}
    assert probe_dims(tail) == {@canvas_w, @canvas_h}
  end

  test "drift without a next anchor (last scene) fills the window alone", ctx do
    scene = %{index: 1, window_ms: 2_400, from: "unused", to: nil, prompt: "x"}

    [seg] =
      Mix.Tasks.Sinestesia.Video.motion_segment(scene, ctx.clip, %{}, @canvas_w, @canvas_h, ctx.dir, 1_500, true)

    assert_in_delta probe_duration_s(seg), 2.4, 0.15
  end

  test "a failed clip degrades to the held still for the window", ctx do
    scene = %{index: 2, window_ms: 2_000, from: "anchor.jpg", to: "next.jpg", prompt: "x"}

    [seg] =
      Mix.Tasks.Sinestesia.Video.motion_segment(
        scene,
        nil,
        %{"anchor.jpg" => ctx.anchor},
        @canvas_w,
        @canvas_h,
        ctx.dir,
        1_500,
        true
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
