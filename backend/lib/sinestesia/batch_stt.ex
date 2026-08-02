defmodule Sinestesia.BatchStt do
  @moduledoc """
  Transcribes a FINISHED recording into a replay session — the offline
  counterpart to the live STT modules.

  `Sinestesia.ElevenSTT` and `Sinestesia.LocalWhisperSTT` are realtime: they
  hold a socket open and emit partials as the voice arrives. Turning an
  already-recorded take into a session (`mix sinestesia.video`) is a
  different question — the whole file at once, with per-word timings — so it
  gets its own module rather than contorting the streaming ones.

  What it is NOT is a different stack. Providers are the same ones the show
  already uses, chosen by the same `STT_PROVIDER`, authenticated by the same
  keys, over `Req` like every other HTTP integration here:

    * `elevenlabs` — Scribe's batch endpoint (`timestamps_granularity=word`).
    * `local_whisper` — the existing `local-whisper/` sidecar's `/transcribe_file`,
      the same service `LocalWhisperSTT` streams to, asked for one file.

  The output is the session-event stream the replay harness consumes:
  growing partials per word, a `final` at each phrase boundary — mimicking
  what the realtime STT emits live, so the Director fires on the same
  fragments it sees on stage.
  """
  require Logger

  @type word :: %{text: String.t(), start: float(), end: float()}
  @type event :: %{at_ms: non_neg_integer(), text: String.t(), final: boolean()}

  @eleven_url "https://api.elevenlabs.io/v1/speech-to-text"
  @eleven_model "scribe_v1"

  # Sung lines usually end on a comma; batch transcription does no VAD, so
  # punctuation is the primary phrase boundary (see segment/2).
  @sentence_end ~w(. ? ! …)
  @phrase_end ~w(, ; :) ++ @sentence_end

  @doc """
  Extract the audio track of `video` to a 16 kHz mono wav next to it.

  16k mono is what every STT here wants, and it is small enough to keep
  around — `mix sinestesia.video --session` reuses it.
  """
  @spec extract_audio(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def extract_audio(video, out_dir) do
    wav = Path.join(out_dir, Path.rootname(Path.basename(video)) <> ".wav")

    args = ["-y", "-v", "error", "-i", video, "-vn", "-ac", "1", "-ar", "16000", wav]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, wav}
      {out, status} -> {:error, {:ffmpeg_failed, status, String.slice(out, -800, 800)}}
    end
  end

  @doc """
  Which batch provider to use: `STT_PROVIDER` when it names one this module
  implements and its prerequisites are met, else `:local_whisper`.

  The live setting is honoured so an operator who configured ElevenLabs for
  the stage doesn't have to configure transcription twice. Providers with no
  batch API here (deepgram, replay) fall through to the local sidecar, which
  needs no key at all.
  """
  @spec provider() :: :elevenlabs | :local_whisper
  def provider do
    if System.get_env("STT_PROVIDER") in ["elevenlabs", "both"] and api_key() != nil,
      do: :elevenlabs,
      else: :local_whisper
  end

  @doc """
  Transcribe `audio` (a wav path) into word timings.

  `lang` is an ISO code, or `""` to let the provider auto-detect — the right
  default here, unlike the stage's `ELEVEN_LANG=pt`, because an uploaded clip
  can be in any language and forcing the wrong one mangles the words badly
  enough to break song identification downstream.
  """
  @spec transcribe(Path.t(), keyword()) :: {:ok, [word()]} | {:error, term()}
  def transcribe(audio, opts \\ []) do
    prov = Keyword.get(opts, :provider) || provider()
    lang = Keyword.get(opts, :lang, "")

    Logger.info("[batch_stt:#{prov}] transcribing #{Path.basename(audio)} (lang: #{lang_label(lang)})")

    case call(prov, audio, lang) do
      {:ok, []} ->
        {:error, :no_words}

      {:ok, words} ->
        Logger.info("[batch_stt:#{prov}] #{length(words)} words, #{round(List.last(words).end)}s")
        {:ok, words}

      error ->
        error
    end
  end

  @doc """
  Word timings → replay session events.

  Batch transcription does no VAD — consecutive word timings are tight even
  across breaths — so the utterance is committed on PUNCTUATION, with a
  silence longer than `gap_s` as the fallback for instrumental breaks. That
  reproduces what the live VAD produces from the same performance.
  """
  @spec segment([word()], float()) :: [event()]
  def segment(words, gap_s \\ 0.6) do
    {events, pending, _prev_end} =
      words
      |> Enum.with_index()
      |> Enum.reduce({[], [], nil}, fn {w, i}, {events, utter, prev_end} ->
        # A long silence commits whatever was pending before this word.
        {events, utter} =
          if prev_end && w.start - prev_end > gap_s && utter != [] do
            {events ++ [final_event(prev_end, utter)], []}
          else
            {events, utter}
          end

        utter = utter ++ [w.text]
        next = Enum.at(words, i + 1)
        commit? = ends_phrase?(w.text) or is_nil(next) or next.start - w.end > gap_s

        # Growing partial; the trailing "-" mid-phrase mimics the live
        # mid-word cut the streaming STT produces.
        text = Enum.join(utter, " ") <> if commit?, do: "", else: "-"
        events = events ++ [%{at_ms: ms(w.end), text: text, final: false}]

        if commit?,
          do: {events ++ [final_event(w.end, utter)], [], w.end},
          else: {events, utter, w.end}
      end)

    events =
      if pending == [],
        do: events,
        else: events ++ [final_event(List.last(words).end, pending)]

    # at_ms must be monotonic for the replay clock; a partial sorts before
    # the final that shares its timestamp.
    Enum.sort_by(events, &{&1.at_ms, &1.final})
  end

  @doc "Full pipeline: video → session map ready for `mix sinestesia.replay`."
  @spec session_from_video(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def session_from_video(video, out_dir, opts \\ []) do
    File.mkdir_p!(out_dir)

    with {:ok, wav} <- extract_audio(video, out_dir),
         {:ok, words} <- transcribe(wav, opts) do
      events = segment(words, Keyword.get(opts, :gap_s, 0.6))

      {:ok,
       %{
         "name" => Keyword.get(opts, :name) || slug(Path.rootname(Path.basename(video))),
         # The extracted wav, not the video: everything downstream that
         # touches "audio" wants a file it can probe.
         "audio" => Path.expand(wav),
         "video" => Path.expand(video),
         "events" => Enum.map(events, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
       }}
    end
  end

  # ── providers ────────────────────────────────────────────────────────────

  defp call(:elevenlabs, audio, lang) do
    key = api_key() || throw(:no_key)

    # Req's multipart parts are `{name, value}` or `{name, {value, options}}`
    # — the options belong INSIDE the tuple, not as a third element. A
    # %File.Stream{} fills in filename and content-type from the path on its
    # own, and streams rather than loading the whole wav into memory.
    fields =
      [
        {"model_id", @eleven_model},
        {"timestamps_granularity", "word"},
        {"file", {File.stream!(audio, 64_000), []}}
      ] ++ if lang == "", do: [], else: [{"language_code", lang}]

    case Req.post(@eleven_url,
           form_multipart: fields,
           headers: [{"xi-api-key", key}],
           receive_timeout: 300_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"words" => words}}} ->
        {:ok,
         words
         |> Enum.filter(&(&1["type"] == "word"))
         |> Enum.map(&%{text: &1["text"], start: &1["start"], end: &1["end"]})}

      {:ok, %{status: status, body: body}} ->
        {:error, {:bad_status, status, inspect(body) |> String.slice(0, 300)}}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :no_key -> {:error, :no_api_key}
  end

  # The sidecar's batch endpoint takes the raw wav bytes as the body — no
  # multipart to parse on either side — and reuses the model that process
  # already has warm. Its own port, since the websocket port + 1 would land on
  # the local SDXL sidecar in a fully-offline setup.
  defp call(:local_whisper, audio, lang) do
    port = batch_port()
    query = if lang == "", do: "", else: "?language=#{lang}"
    url = "http://#{whisper_host()}:#{port}/transcribe_file#{query}"

    case Req.post(url,
           body: File.read!(audio),
           headers: [{"content-type", "audio/wav"}],
           receive_timeout: 600_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"words" => words}}} ->
        {:ok, Enum.map(words, &%{text: &1["text"], start: &1["start"], end: &1["end"]})}

      {:ok, %{status: 404}} ->
        {:error, {:sidecar_too_old, "the local-whisper sidecar has no /transcribe_file — update it"}}

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error,
         {:sidecar_down, "start it with: cd local-whisper && .venv/bin/python server.py"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Env first, app config second: this module is called by `mix
  # sinestesia.video` BEFORE the app boots (transcription decides what to
  # load), and `Application.fetch_env!` would raise there. runtime.exs sets
  # :elevenlabs_api_key from this very variable, so the two agree.
  defp api_key do
    case System.get_env("ELEVENLABS_API_KEY") do
      k when is_binary(k) and k != "" ->
        k

      _ ->
        case Application.get_env(:sinestesia, :config, []) |> Keyword.get(:elevenlabs_api_key) do
          k when is_binary(k) and k != "" -> k
          _ -> nil
        end
    end
  end

  defp whisper_host, do: System.get_env("LOCAL_WHISPER_HOST", "127.0.0.1")
  defp batch_port, do: System.get_env("LOCAL_WHISPER_BATCH_PORT", "8012")

  defp lang_label(""), do: "auto-detect"
  defp lang_label(l), do: l

  defp final_event(at, utter), do: %{at_ms: ms(at), text: Enum.join(utter, " "), final: true}

  defp ms(seconds), do: round(seconds * 1000)

  defp ends_phrase?(text) do
    text |> String.trim_trailing() |> String.last() |> Kernel.in(@phrase_end)
  end

  defp slug(s) do
    s
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
