defmodule Sinestesia.ImageGenDeadlineTest do
  use ExUnit.Case, async: false

  alias Sinestesia.ImageGen

  # One deadline for every frame, never above 10 s: the founder's rule
  # (2026-11-02, HANDOFF #52). The provider is not involved here — the
  # deadline wraps whatever generate/2 runs.

  setup do
    prev = System.get_env("IMAGE_TIMEOUT_MS")
    on_exit(fn -> if prev, do: System.put_env("IMAGE_TIMEOUT_MS", prev), else: System.delete_env("IMAGE_TIMEOUT_MS") end)
    :ok
  end

  describe "timeout_ms/0" do
    test "defaults to the 10 s ceiling" do
      System.delete_env("IMAGE_TIMEOUT_MS")
      assert ImageGen.timeout_ms() == 10_000
    end

    test "never exceeds 10 s whatever the env says" do
      System.put_env("IMAGE_TIMEOUT_MS", "30000")
      assert ImageGen.timeout_ms() == 10_000
    end

    test "accepts a tighter budget, and ignores nonsense" do
      System.put_env("IMAGE_TIMEOUT_MS", "6000")
      assert ImageGen.timeout_ms() == 6_000
      System.put_env("IMAGE_TIMEOUT_MS", "banana")
      assert ImageGen.timeout_ms() == 10_000
      System.put_env("IMAGE_TIMEOUT_MS", "200")
      assert ImageGen.timeout_ms() == 10_000
    end

    test "the providers' backstop sits just past it" do
      System.put_env("IMAGE_TIMEOUT_MS", "6000")
      assert ImageGen.backstop_timeout_ms() == 7_000
    end

    # mix sinestesia.video renders offline — no audience, so a 20 s frame
    # beats a hole in the film. The ceiling moves; the default does not.
    test "an offline render can lift the ceiling, and the default stays 10 s" do
      on_exit(fn -> Application.delete_env(:sinestesia, :image_timeout_ceiling_ms) end)
      ImageGen.lift_timeout_ceiling(120_000)

      System.put_env("IMAGE_TIMEOUT_MS", "20000")
      assert ImageGen.timeout_ms() == 20_000
      System.put_env("IMAGE_TIMEOUT_MS", "500000")
      assert ImageGen.timeout_ms() == 120_000
      System.delete_env("IMAGE_TIMEOUT_MS")
      assert ImageGen.timeout_ms() == 10_000
    end

    test "the ceiling can only be lifted, never lowered below the stage's 10 s" do
      assert_raise FunctionClauseError, fn -> ImageGen.lift_timeout_ceiling(3_000) end
    end
  end

  describe "within_deadline/2" do
    # The abandoned line says how many other frames a slow one was competing
    # with — "the provider is slow" and "we are queueing on our own key" are
    # different problems with different fixes.
    test "counts the frames in flight while a render runs, and lets go after" do
      ImageGen.init_in_flight()
      assert ImageGen.in_flight() == 0

      assert {:ok, 1} == ImageGen.within_deadline(fn -> {:ok, ImageGen.in_flight()} end, 1_000)
      assert ImageGen.in_flight() == 0

      # The count comes back down even when the frame is abandoned.
      assert {:error, :image_timeout} = ImageGen.within_deadline(fn -> Process.sleep(500) end, 50)
      assert ImageGen.in_flight() == 0
    end

    test "a frame that takes too long is abandoned, and the route it noted survives for the log" do
      Process.delete(:image_route)

      result =
        ImageGen.within_deadline(
          fn ->
            ImageGen.note_route("i2i", "slow-model", nil, seed_bytes: 1_400_000)
            Process.sleep(2_000)
            {:ok, "never"}
          end,
          100
        )

      assert result == {:error, :image_timeout}
      assert %{route: "i2i", model: "slow-model", seed_bytes: 1_400_000} = ImageGen.last_route()
    end

    test "a frame in time comes back with its route and morph cost in the caller's process" do
      Process.delete(:image_route)
      Process.delete(:morph_ms)

      result =
        ImageGen.within_deadline(
          fn ->
            ImageGen.note_route("t2i", "fast-model", 4)
            Process.put(:morph_ms, 321)
            {:ok, "data:image/png;base64,AAAA"}
          end,
          1_000
        )

      assert result == {:ok, "data:image/png;base64,AAAA"}
      assert %{route: "t2i", model: "fast-model", steps: 4} = ImageGen.last_route()
      assert Process.get(:morph_ms) == 321
    end

    test "describe_route/1 says what was on the wire" do
      assert ImageGen.describe_route(%{provider: "google", route: "i2i", model: "m", seed_bytes: 1_400_000}) ==
               "google m i2i, seed image 1.3 MB uploaded inline"

      assert ImageGen.describe_route(%{provider: "fal", route: "t2i", model: "flux", steps: 4}) == "fal flux t2i"
    end
  end
end
