defmodule Sinestesia.SongLibrary do
  @moduledoc """
  A persistent catalog of known songs: paste (or import) a song's lyrics
  once, reuse it across every future show without re-pasting — and, once
  auto-identification is wired into the pipeline, without even loading it by
  hand.

  One JSON file per song in `SONGS_DIR` (default `../songs`, resolved
  relative to the backend's own working directory — the same convention
  `tests/sessions/` already uses for `mix sinestesia.replay`). Deliberately
  plain files, not a database: this catalog is small (a working set of songs
  an artist actually performs, not a music-industry-scale library), and
  plain JSON means `git`, `cp`, and manual editing all just work, matching
  how `tests/sessions/*.json` already works for replay recordings.

  ## Song shape

      %{
        id: "aquarela",                 # slug, also the filename (id.json)
        title: "Aquarela do Brasil",
        artist: "Toquinho",
        style: nil,                     # pinned visual style, or nil = use current
        source_url: "https://...",      # where it was imported from, if any
        lyrics_text: "...",             # raw text, blank lines = stanza breaks
        added_at: "2026-07-31T12:00:00Z"
      }
  """
  require Logger

  @type song :: %{
          id: String.t(),
          title: String.t(),
          artist: String.t() | nil,
          style: String.t() | nil,
          source_url: String.t() | nil,
          lyrics_text: String.t(),
          added_at: String.t()
        }

  @doc "Where song files live. `SONGS_DIR` overrides; default is `../songs` from the backend's cwd."
  @spec dir() :: String.t()
  def dir do
    System.get_env("SONGS_DIR", Path.expand("../songs", File.cwd!()))
  end

  @doc "List every song's id/title/artist (not the full lyrics — see get/1), sorted by title."
  @spec list() :: [%{id: String.t(), title: String.t(), artist: String.t() | nil}]
  def list do
    dir()
    |> song_files()
    |> Enum.map(&load_file/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Map.take(&1, [:id, :title, :artist]))
    |> Enum.sort_by(& &1.title)
  end

  @doc "Fetch a song's full record by id, or nil."
  @spec get(String.t()) :: song() | nil
  def get(id) when is_binary(id) do
    path = Path.join(dir(), "#{id}.json")
    if File.exists?(path), do: load_file(path), else: nil
  end

  @doc """
  Save (create or update) a song. `title` is required; `id` defaults to a
  slug of the title when not given. Returns the saved song, id included.
  """
  @spec save(map()) :: {:ok, song()} | {:error, term()}
  def save(%{title: title} = attrs) when is_binary(title) and title != "" do
    id = Map.get(attrs, :id) || slugify(title)

    song = %{
      id: id,
      title: title,
      artist: presence(Map.get(attrs, :artist)),
      style: presence(Map.get(attrs, :style)),
      source_url: presence(Map.get(attrs, :source_url)),
      lyrics_text: Map.get(attrs, :lyrics_text, ""),
      added_at: Map.get(attrs, :added_at) || DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- File.mkdir_p(dir()),
         {:ok, json} <- Jason.encode(song, pretty: true),
         :ok <- File.write(Path.join(dir(), "#{id}.json"), json) do
      {:ok, song}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def save(_), do: {:error, :title_required}

  @doc "Delete a song by id. Idempotent — deleting a non-existent id is not an error."
  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    path = Path.join(dir(), "#{id}.json")
    File.rm(path)
    :ok
  end

  @doc """
  Identify which known song a few sung words most likely belong to, by
  matching against each song's OPENING line. Distinct from
  `Sinestesia.PerformanceFollower.match/4` (which tracks position within ONE
  already-known song): this searches ACROSS every song in the library.

  Openings tend to be distinctive, but a short sung fragment (2-4 words) is
  inherently more ambiguous than the per-line matching the follower does once
  a song is already identified — so the threshold defaults higher
  (`SONG_IDENTIFY_THRESHOLD`, 0.7) than the follower's own default, and a
  wrong guess costs only a discarded speculative render (the same graceful
  fallback the rest of the look-ahead machinery already relies on), never a
  worse outcome than not guessing at all.

  Returns `{:match, song}` or `:no_match`.
  """
  @spec identify(String.t(), keyword()) :: {:match, song()} | :no_match
  def identify(sung_text, opts \\ []) when is_binary(sung_text) do
    threshold = Keyword.get(opts, :threshold, default_threshold())

    list()
    |> Enum.map(&get(&1.id))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn song -> {song, match_score(sung_text, opening_line(song))} end)
    |> Enum.filter(fn {_song, score} -> score >= threshold end)
    |> Enum.sort_by(fn {_song, score} -> -score end)
    |> case do
      [{song, _score} | _] -> {:match, song}
      [] -> :no_match
    end
  end

  defp default_threshold do
    case Float.parse(System.get_env("SONG_IDENTIFY_THRESHOLD", "0.7")) do
      {t, _} when t > 0 and t <= 1 -> t
      _ -> 0.7
    end
  end

  defp opening_line(%{lyrics_text: text}) do
    text
    |> Sinestesia.PerformanceFollower.normalize()
    |> List.first()
  end

  # Overlap coefficient against the song's opening line, same measure
  # PerformanceFollower uses for in-song position tracking (but PerformanceFollower.match/4
  # is shaped for "match one line against nearby candidates in ONE known
  # script", not "rank this fragment against many songs' openings" — so this
  # is computed directly rather than borrowed).
  defp match_score(_sung_text, nil), do: 0.0

  defp match_score(sung_text, opening_line) do
    sung = tokens(sung_text)
    line = tokens(opening_line)
    denom = min(MapSet.size(sung), MapSet.size(line))
    if denom == 0, do: 0.0, else: MapSet.size(MapSet.intersection(sung, line)) / denom
  end

  # Mirrors Sinestesia.PerformanceFollower's tokenizer, including the
  # held-vowel collapse (runs of THREE or more only — two-letter runs are real
  # words like "moon"/"carro"/"corro", not held notes; see that module for the
  # full reasoning). Identification compares the first SUNG words against
  # every catalog song's opening, so it hits "folhaaa"/"amarelooo" for exactly
  # the same reason position tracking does — and here a false merge is worse,
  # since it ranks DIFFERENT songs against each other. Kept as its own copy
  # rather than shared because the two answer different questions (see HANDOFF
  # gotcha #31) and neither should silently change when the other is tuned.
  defp tokens(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/(.)\1{2,}/u, "\\1")
    |> String.split(~r/\s+/, trim: true)
    |> MapSet.new()
  end

  defp song_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp load_file(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw, keys: :atoms) do
      json
    else
      {:error, reason} ->
        Logger.warning("[song_library] couldn't read #{path}: #{inspect(reason)}")
        nil
    end
  end

  defp slugify(title) do
    title
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp presence(_), do: nil
end
