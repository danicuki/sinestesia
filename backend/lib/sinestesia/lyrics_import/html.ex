defmodule Sinestesia.LyricsImport.Html do
  @moduledoc """
  Minimal HTML text-cleanup shared by the per-site lyrics parsers. Deliberately
  NOT a general HTML parser (no Floki dependency added for two narrow, known
  page shapes) — just enough to strip tags and unescape the handful of
  entities that actually show up on these pages. Both source sites serve
  accented characters as raw UTF-8 (verified against live fetches), not
  numeric entities, so this only needs to cover markup entities.
  """

  @doc "Strip any remaining HTML tags from a fragment."
  @spec strip_tags(String.t()) :: String.t()
  def strip_tags(text) do
    Regex.replace(~r/<[^>]*>/, text, "")
  end

  @doc "Decode the handful of HTML entities these pages actually use."
  @spec unescape(String.t()) :: String.t()
  def unescape(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  @doc "strip_tags |> unescape |> trim — the common per-line/per-field cleanup."
  @spec clean(String.t()) :: String.t()
  def clean(text) do
    text |> strip_tags() |> unescape() |> String.trim()
  end
end
