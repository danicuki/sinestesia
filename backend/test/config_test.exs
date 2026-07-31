defmodule Sinestesia.ConfigTest do
  @moduledoc """
  Keeps `Sinestesia.Config` honest.

  Documentation drifts because nothing fails when it does. These tests are the
  thing that fails: add an env var to the code without registering it, or change
  a default without regenerating the docs, and the build breaks with the exact
  command to fix it.
  """
  # Not async: these tests set process-global env vars to exercise resolution.
  use ExUnit.Case, async: false

  # Most settings are read where they're used, in lib/. The handful that become
  # application env (API keys, Ollama) are read in config/runtime.exs, so both
  # count as "the code reads this".
  @sources [Path.expand("../lib", __DIR__), Path.expand("../config", __DIR__)]

  # Reading an env var that isn't a *setting* — an internal flag, a var owned by
  # another tool — is legitimate. Listing it here is the deliberate act of
  # saying so, rather than the accident of forgetting.
  @not_settings ~w(MIX_ENV)

  describe "every env var the code reads is registered" do
    test "no unregistered System.get_env/1,2 calls in lib/" do
      registered = MapSet.new(Sinestesia.Config.specs(), & &1.key)

      unregistered =
        env_vars_read()
        |> Enum.reject(&(&1 in @not_settings))
        |> Enum.reject(&MapSet.member?(registered, &1))

      assert unregistered == [], """
      These environment variables are read in lib/ but are not registered in
      Sinestesia.Config:

        #{Enum.join(unregistered, "\n  ")}

      Add them to @specs in lib/sinestesia/config.ex, then run:

        mix sinestesia.config --write

      An unregistered setting is invisible: it won't appear in the boot banner,
      in GET /config, or in CONFIGURATION.md.
      """
    end

    test "no registered setting is dead" do
      read = MapSet.new(env_vars_read())

      dead =
        Sinestesia.Config.specs()
        |> Enum.map(& &1.key)
        |> Enum.reject(&MapSet.member?(read, &1))

      assert dead == [], """
      These settings are registered in Sinestesia.Config but nothing in lib/
      reads them — they were removed from the code, or renamed:

        #{Enum.join(dead, "\n  ")}

      Documenting a knob that does nothing is worse than not documenting it.
      """
    end
  end

  describe "CONFIGURATION.md" do
    test "is in sync with the registry" do
      path = Mix.Tasks.Sinestesia.Config.doc_path()

      assert File.read!(path) == Mix.Tasks.Sinestesia.Config.rendered_doc(), """
      CONFIGURATION.md no longer matches Sinestesia.Config. Regenerate it:

        mix sinestesia.config --write
      """
    end
  end

  describe "render_mode" do
    # Spelling is about parsing what the operator typed, so it's checked against
    # requested_render_mode/0 — render_mode/0 additionally applies provider
    # capabilities, which is a separate question (see "provider capabilities").
    test "normalises every spelling the codebase has used" do
      for spelling <- ~w(t2i T2I text2img txt2img text2image) do
        assert with_env("RENDER_MODE", spelling, &Sinestesia.ImageGen.requested_render_mode/0) ==
                 :t2i
      end

      for spelling <- ~w(i2i I2I img2img image2image) do
        assert with_env("RENDER_MODE", spelling, &Sinestesia.ImageGen.requested_render_mode/0) ==
                 :i2i
      end
    end

    test "defaults to i2i, and anything unrecognised is i2i rather than a crash" do
      assert with_env("RENDER_MODE", nil, &Sinestesia.ImageGen.requested_render_mode/0) == :i2i

      assert with_env("RENDER_MODE", "nonsense", &Sinestesia.ImageGen.requested_render_mode/0) ==
               :i2i
    end
  end

  describe "provider capabilities" do
    # The bug this prevents (seen live on google, back when it was Imagen and
    # had no i2i): with RENDER_MODE=i2i + COMPOSE_MODE=inpaint the previous
    # frame and the placement were silently discarded, and a `NEW: a yellow
    # sun | POS: top` delta — meaningful only to an inpainter — became the
    # entire prompt for an independent render. Every frame came out an
    # isolated object on an unrelated canvas.
    test "i2i is downgraded to t2i on providers that have no image-to-image" do
      for provider <- ~w(pollinations) do
        # IMAGE_MODE is pinned: left ambient, this test would report a different
        # set of conflicts depending on what the developer's .env happens to say.
        with_envs(
          %{"IMAGE_PROVIDER" => provider, "RENDER_MODE" => "i2i", "IMAGE_MODE" => "classic"},
          fn ->
            assert Sinestesia.ImageGen.requested_render_mode() == :i2i
            assert Sinestesia.ImageGen.render_mode() == :t2i
            assert [{:downgrade, msg}] = Sinestesia.Config.conflicts()
            assert msg =~ "no image-to-image endpoint"
          end
        )
      end
    end

    test "i2i is honoured on providers that have it" do
      for provider <- ~w(fal cloudflare local_sdxl google) do
        with_envs(%{"IMAGE_PROVIDER" => provider, "RENDER_MODE" => "i2i"}, fn ->
          assert Sinestesia.ImageGen.render_mode() == :i2i
        end)
      end
    end

    test "element deltas are only emitted for providers that can inpaint" do
      base = %{"IMAGE_MODE" => "story", "RENDER_MODE" => "i2i", "COMPOSE_MODE" => "inpaint"}

      for provider <- ~w(fal local_sdxl) do
        with_envs(Map.put(base, "IMAGE_PROVIDER", provider), fn ->
          assert Sinestesia.Director.compose?()
        end)
      end

      for provider <- ~w(cloudflare google pollinations) do
        with_envs(Map.put(base, "IMAGE_PROVIDER", provider), fn ->
          refute Sinestesia.Director.compose?(),
                 "#{provider} cannot inpaint, so it must get whole-scene prompts"
        end)
      end
    end

    test "a fully supported combination reports no conflicts" do
      with_envs(
        %{
          "IMAGE_PROVIDER" => "fal",
          "RENDER_MODE" => "i2i",
          "COMPOSE_MODE" => "inpaint",
          "IMAGE_MODE" => "story"
        },
        fn -> assert Sinestesia.Config.conflicts() == [] end
      )
    end

    test "every provider the dispatcher accepts has a capability entry" do
      for provider <- ~w(fal cloudflare google pollinations local_sdxl) do
        with_envs(%{"IMAGE_PROVIDER" => provider}, fn ->
          caps = Sinestesia.ImageGen.capabilities()
          assert caps.t2i, "#{provider} must be able to open a song"
          assert is_boolean(caps.i2i) and is_boolean(caps.inpaint)
        end)
      end
    end
  end

  describe "banner" do
    test "never prints a secret's value" do
      secret = "sk-do-not-print-me-0123456789"
      key = "ELEVENLABS_API_KEY"

      banner = with_env(key, secret, &Sinestesia.Config.banner/0)

      refute banner =~ secret
      assert banner =~ key
      # ...but enough to tell two keys apart and prove the right file loaded.
      assert banner =~ "6789"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp with_envs(vars, fun) do
    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp with_env(key, value, fun) do
    previous = System.get_env(key)
    if value, do: System.put_env(key, value), else: System.delete_env(key)

    try do
      fun.()
    after
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end
  end

  # Scrape `System.get_env("FOO"` out of the source. Crude on purpose: the
  # alternative is asking each module to declare what it reads, which is exactly
  # the bookkeeping that didn't get done.
  defp env_vars_read do
    @sources
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.{ex,exs}")))
    |> Enum.flat_map(fn file ->
      # `System.get_env("FOO"`, and runtime.exs's local `get_env.("FOO"` helper.
      Regex.scan(
        ~r/(?:System\.(?:get_env|put_env|fetch_env!?)|get_env\.)\("([A-Z][A-Z0-9_]*)"/,
        File.read!(file)
      )
    end)
    |> Enum.map(fn [_, key] -> key end)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
