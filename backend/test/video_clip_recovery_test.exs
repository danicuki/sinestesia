defmodule Mix.Tasks.Sinestesia.VideoClipRecoveryTest do
  use ExUnit.Case, async: true

  # The three-layer recovery, learned from a live run that lost scenes 9
  # and 10: "high demand" retries, a safety refusal retries once with the
  # neutral direction, and finished clips are cached so a rerun re-pays
  # only what it didn't get.

  defmodule FakeEngine do
    # Scripted via the test process dictionary — generate_clip runs in the
    # caller's process, so the test controls each await's outcome and can
    # read back every submitted prompt.
    def submit(prompt, _from, _opts) do
      Process.put(:prompts, Process.get(:prompts, []) ++ [prompt])
      {:ok, :ref}
    end

    def await(:ref, dest) do
      [next | rest] = Process.get(:script)
      Process.put(:script, rest)

      case next do
        :ok ->
          File.write!(dest, "a-clip")
          {:ok, dest}

        error ->
          {:error, error}
      end
    end
  end

  @high_demand {:no_video,
                %{
                  error: %{"code" => 14, "message" => "This model is currently experiencing high demand."},
                  filtered_count: nil,
                  filtered_reasons: nil
                }}

  @refusal {:no_video,
            %{error: nil, filtered_count: 1, filtered_reasons: ["conflicted with our safety policies"]}}

  setup do
    dir = Path.join(System.tmp_dir!(), "clip-rec-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Process.put(:prompts, [])
    %{dir: dir, opts: base_opts()}
  end

  defp base_opts do
    [
      engine: FakeEngine,
      model: "fake",
      resolution: "720p",
      aspect_ratio: "16:9",
      style_suffix: nil,
      safe_direction: "gentle neutral drift",
      transient_wait_ms: 0,
      clip_cache_dir: nil
    ]
  end

  defp generate(direction, dir, opts),
    do: Mix.Tasks.Sinestesia.Video.generate_clip(0, direction, 4, nil, nil, dir, opts)

  test "a high-demand spike is retried with the SAME direction", ctx do
    Process.put(:script, [@high_demand, :ok])

    assert {:ok, _} = generate("waves roll in", ctx.dir, ctx.opts)
    assert Process.get(:prompts) == ["waves roll in", "waves roll in"]
  end

  test "a safety refusal retries ONCE with the neutral direction", ctx do
    Process.put(:script, [@refusal, :ok])

    assert {:ok, _} = generate("something too spicy", ctx.dir, ctx.opts)
    assert Process.get(:prompts) == ["something too spicy", "gentle neutral drift"]
  end

  test "a refusal of the neutral direction too gives up (freeze, not loop)", ctx do
    Process.put(:script, [@refusal, @refusal])

    assert :error = generate("spicy", ctx.dir, ctx.opts)
    assert length(Process.get(:prompts)) == 2
  end

  test "transient retries are bounded", ctx do
    Process.put(:script, [@high_demand, @high_demand, @high_demand])

    assert :error = generate("waves", ctx.dir, ctx.opts)
    assert length(Process.get(:prompts)) == 3
  end

  test "a finished clip is served from cache — the engine is never called again", ctx do
    cache_dir = Path.join(ctx.dir, "clips")
    opts = Keyword.put(ctx.opts, :clip_cache_dir, cache_dir)

    Process.put(:script, [:ok])
    assert {:ok, _} = generate("waves roll in", ctx.dir, opts)

    # Empty script: any engine call now would crash the test.
    Process.put(:script, [])
    assert {:ok, clip} = generate("waves roll in", ctx.dir, opts)
    assert File.read!(clip) == "a-clip"
    assert Process.get(:prompts) == ["waves roll in"]
  end

  test "a different direction is a different cache entry", ctx do
    cache_dir = Path.join(ctx.dir, "clips")
    opts = Keyword.put(ctx.opts, :clip_cache_dir, cache_dir)

    Process.put(:script, [:ok, :ok])
    assert {:ok, _} = generate("waves roll in", ctx.dir, opts)
    assert {:ok, _} = generate("clouds part", ctx.dir, opts)
    assert length(Process.get(:prompts)) == 2
  end
end
