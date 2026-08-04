defmodule Mix.Tasks.Sinestesia.VideoComposeTest do
  use ExUnit.Case, async: true

  # Regression for the first Mac run with IMAGE_PROVIDER=google (2026-08-04):
  # Gemini returns different dimensions per generation (1376x768 then
  # 1408x768). blend_steps normalized to the DESTINATION frame's size
  # instead of the canvas, and norm's cache key ignored dimensions — so a
  # cached 1376x768 normalization was returned where 1408x768 was asked
  # for, and ffmpeg's blend filter killed the whole composition:
  #   "First input link top parameters (size 1376x768) do not match the
  #    corresponding second input link bottom parameters (size 1408x768)"
  #
  # The contract this test pins: EVERY file referenced by the concat script
  # has exactly the canvas dimensions, no matter what sizes the provider
  # returned.

  defp mk_frame(dir, name, w, h) do
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -v error -f lavfi -i color=c=gray:s=#{w}x#{h} -frames:v 1) ++ [path],
        stderr_to_stdout: true
      )

    path
  end

  defp dims(path) do
    {out, 0} =
      System.cmd("ffprobe", [
        "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
        "-of", "csv=s=x:p=0", path
      ])

    String.trim(out)
  end

  test "mismatched provider dimensions all land on the canvas" do
    dir = Path.join(System.tmp_dir!(), "compose-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    frames = [
      %{at_ms: 1_000, file: mk_frame(dir, "f1.jpg", 1376, 768), subfiles: []},
      %{at_ms: 8_000, file: mk_frame(dir, "f2.jpg", 1408, 768), subfiles: []},
      %{at_ms: 15_000, file: mk_frame(dir, "f3.jpg", 1376, 768), subfiles: []}
    ]

    # Canvas comes from the first frame, same as compose/6 does.
    concat = Mix.Tasks.Sinestesia.Video.build_concat(frames, 1_500, 20_000, 1376, 768, dir)

    files =
      concat
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn
        "file '" <> rest -> [String.trim_trailing(rest, "'")]
        _ -> []
      end)
      |> Enum.uniq()

    assert files != []

    for file <- files do
      assert dims(file) == "1376x768",
             "#{Path.basename(file)} is #{dims(file)}, not the canvas — ffmpeg's blend/concat would refuse it"
    end
  end
end
