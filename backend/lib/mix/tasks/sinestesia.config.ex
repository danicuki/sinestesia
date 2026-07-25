defmodule Mix.Tasks.Sinestesia.Config do
  @shortdoc "Show the resolved configuration, or regenerate CONFIGURATION.md"

  @moduledoc """
  Answer "what is this box actually configured to do?" without booting a show.

      mix sinestesia.config              # the boot banner, printed now
      mix sinestesia.config --json       # same, as JSON (secrets redacted)
      mix sinestesia.config --markdown   # the generated settings reference
      mix sinestesia.config --write      # write that reference into CONFIGURATION.md

  `--write` is the one that matters: the settings table in `CONFIGURATION.md`
  is generated from `Sinestesia.Config`, so it cannot drift the way a
  hand-maintained table did. `test/config_test.exs` fails the build when the
  file on disk no longer matches.
  """
  use Mix.Task

  @doc_path Path.expand("../../../../CONFIGURATION.md", __DIR__)
  @begin "<!-- BEGIN GENERATED SETTINGS -->"
  @end_ "<!-- END GENERATED SETTINGS -->"

  @impl true
  def run(args) do
    # The task only reads config; no need to start listeners (and boot would
    # fail anyway when a real backend already holds the port).
    Mix.Task.run("app.config")
    Application.ensure_all_started(:jason)

    cond do
      "--json" in args ->
        IO.puts(Jason.encode_to_iodata!(Sinestesia.Config.to_map(), pretty: true))

      "--markdown" in args ->
        IO.puts(Sinestesia.Config.markdown())

      "--write" in args ->
        write_doc()

      true ->
        IO.puts(Sinestesia.Config.banner())
    end
  end

  @doc "The `CONFIGURATION.md` content implied by the current `Sinestesia.Config`."
  def rendered_doc do
    current = File.read!(@doc_path)
    replace_block(current, Sinestesia.Config.markdown())
  end

  @doc "Path to CONFIGURATION.md, so the test can read the same file the task writes."
  def doc_path, do: @doc_path

  defp write_doc do
    updated = rendered_doc()

    if updated == File.read!(@doc_path) do
      Mix.shell().info("CONFIGURATION.md already up to date.")
    else
      File.write!(@doc_path, updated)
      Mix.shell().info("CONFIGURATION.md updated.")
    end
  end

  # Replace only the generated block, so the prose around it — the parts a
  # human wrote and a generator can't — survives regeneration.
  defp replace_block(current, generated) do
    block = "#{@begin}\n\n#{generated}\n#{@end_}"

    case String.split(current, [@begin, @end_]) do
      [before, _old, rest] -> before <> block <> rest
      _ -> String.trim_trailing(current) <> "\n\n" <> block <> "\n"
    end
  end
end
