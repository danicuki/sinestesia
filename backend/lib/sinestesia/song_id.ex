defmodule Sinestesia.SongId do
  @moduledoc """
  Identifies WHICH song was just performed, from the transcribed lyrics.

  Without this the minted NFT is stamped `"Untitled"` — the performance is
  permanent on-chain but says nothing about what was actually played. The
  transcript we hand over is raw STT output: partial, phonetically wrong in
  places, and usually Portuguese, so the prompt is built to tolerate noise and to
  answer `UNKNOWN` rather than invent a plausible-sounding title. A wrong title
  minted forever is worse than no title.

  Runs once per song, off the hot path (inside the mint task), so it can afford a
  slower/better model than the realtime Director: world knowledge of the actual
  song catalogue matters far more than latency here. Providers are tried in
  descending order of that knowledge, falling back to the local model last.
  """
  require Logger

  @timeout_ms 10_000

  @system """
  You identify songs from noisy speech-to-text transcripts of a LIVE vocal performance.

  The transcript is unreliable: words are misheard, lines are partial, and it is often Portuguese (Brazilian MPB, samba, pop). Work from whatever recognisable lyric fragments, hooks or refrains you can find.

  Answer in EXACTLY one of these two forms, with no preamble, quotes or commentary:

  TITLE :: ARTIST
  UNKNOWN

  Rules:
  - Use the song's real, official title and its original recording artist.
  - Reply UNKNOWN unless you actually recognise the song. Never guess a title that merely fits the mood, and never invent an artist.
  - If you recognise the song but not the artist, use: TITLE :: UNKNOWN
  """

  @doc """
  Identify the performed song from its transcript.

  Returns `{:ok, %{title: String.t(), artist: String.t() | nil}}` when a song is
  recognised, or `{:error, reason}` — including `{:error, :unknown}` when the
  model correctly declines to guess.
  """
  @spec identify(String.t()) :: {:ok, %{title: String.t(), artist: String.t() | nil}} | {:error, term()}
  def identify(transcript) when is_binary(transcript) do
    text = String.trim(transcript)

    # Too little to go on — don't burn a call or risk a hallucinated title.
    if String.length(text) < 40 do
      {:error, :transcript_too_short}
    else
      user = """
      TRANSCRIPT of the performance:
      "#{excerpt(text)}"

      Which song is this?
      """

      Enum.reduce_while(providers(), {:error, :no_provider}, fn provider, _acc ->
        case call(provider, user) do
          {:ok, raw} ->
            case parse(raw) do
              {:ok, song} ->
                Logger.info("[songid:#{provider}] #{song.title} :: #{song.artist || "unknown"}")
                {:halt, {:ok, song}}

              {:error, :unknown} ->
                Logger.info("[songid:#{provider}] did not recognise the song")
                {:halt, {:error, :unknown}}
            end

          {:error, reason} ->
            Logger.debug("[songid:#{provider}] #{inspect(reason)}; trying next")
            {:cont, {:error, reason}}
        end
      end)
    end
  end

  def identify(_), do: {:error, :no_transcript}

  # Best world knowledge first. The local model is deliberately NOT in the
  # default chain: asked to name a song it doesn't know, a small local model
  # answers confidently and wrongly (it called Jorge Vercilo's "Homem-Aranha"
  # "Você na Minha Teia" by Jorge e Mateus), and that title gets minted on-chain
  # forever. "Untitled" is recoverable; a confident wrong credit is not. Opt in
  # with SONGID_ALLOW_LOCAL=1 when running fully offline.
  defp providers do
    if System.get_env("SONGID_ALLOW_LOCAL") in ["1", "true"] do
      [:gemini, :haiku, :ollama]
    else
      [:gemini, :haiku]
    end
  end

  # Keep the prompt bounded: the opening and closing stretches carry the title
  # hook and refrain, and a full 4-minute transcript is mostly repetition.
  defp excerpt(text) do
    if String.length(text) <= 2_400 do
      text
    else
      String.slice(text, 0, 1_600) <> " […] " <> String.slice(text, -800, 800)
    end
  end

  defp call(:gemini, user) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :google_api_key) do
      key when is_binary(key) and key != "" ->
        # Full Flash, not Flash-Lite: recognising a specific song from garbled
        # lyrics is a world-knowledge task, and the lite tiers guess more.
        model = System.get_env("SONGID_GEMINI_MODEL", "gemini-3.6-flash")

        url =
          "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

        body = %{
          systemInstruction: %{parts: [%{text: @system}]},
          contents: [%{role: "user", parts: [%{text: user}]}],
          # Gemini 3.x spends maxOutputTokens on thinking before it emits the
          # answer, so a tight budget returns an EMPTY candidate with
          # finishReason MAX_TOKENS. Leave headroom rather than disabling
          # thinking — this model rejects thinkingConfig.thinkingBudget: 0 with
          # a 400, and the reasoning is what recognises a garbled lyric anyway.
          generationConfig: %{temperature: 0.0, maxOutputTokens: 1200}
        }

        case Req.post(url, json: body, receive_timeout: @timeout_ms, retry: false) do
          {:ok, %{status: 200, body: body}} ->
            # Take the first part that actually carries text: responses can lead
            # with non-text (thought) parts, and an exhausted budget yields a
            # candidate with no parts at all.
            case first_text(body) do
              nil -> {:error, {:empty_response, finish_reason(body)}}
              t -> {:ok, t}
            end

          {:ok, resp} -> {:error, {:bad_status, resp.status}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :no_key}
    end
  end

  defp call(:haiku, user) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :anthropic_api_key) do
      key when is_binary(key) and key != "" ->
        body = %{
          model: System.get_env("SONGID_ANTHROPIC_MODEL", "claude-haiku-4-5"),
          max_tokens: 60,
          system: @system,
          messages: [%{role: "user", content: user}]
        }

        headers = [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}]

        case Req.post("https://api.anthropic.com/v1/messages",
               json: body,
               headers: headers,
               receive_timeout: @timeout_ms,
               retry: false
             ) do
          {:ok, %{status: 200, body: %{"content" => [%{"text" => t} | _]}}} when is_binary(t) ->
            {:ok, t}

          {:ok, resp} -> {:error, {:bad_status, resp.status}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :no_key}
    end
  end

  defp call(:ollama, user) do
    cfg = Application.fetch_env!(:sinestesia, :config)
    url = Keyword.fetch!(cfg, :ollama_url) <> "/api/chat"

    body = %{
      model: Keyword.fetch!(cfg, :ollama_model),
      stream: false,
      think: false,
      options: %{temperature: 0.0, num_predict: 60},
      messages: [
        %{role: "system", content: @system},
        %{role: "user", content: user}
      ]
    }

    case Req.post(url, json: body, receive_timeout: @timeout_ms, retry: false) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => t}}}} when is_binary(t) ->
        {:ok, t}

      {:ok, resp} -> {:error, {:bad_status, resp.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_text(%{"candidates" => [%{"content" => content} | _]}) do
    content
    |> Map.get("parts", [])
    |> Enum.find_value(fn
      %{"text" => t} when is_binary(t) -> if String.trim(t) == "", do: nil, else: t
      _ -> nil
    end)
  end

  defp first_text(_), do: nil

  defp finish_reason(%{"candidates" => [%{"finishReason" => r} | _]}), do: r
  defp finish_reason(_), do: :unknown

  # Pull "TITLE :: ARTIST" out of the reply, tolerating stray quotes/markdown.
  defp parse(raw) do
    line =
      raw
      |> String.trim()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "```")))
      |> List.first()
      |> Kernel.||("")

    cond do
      line == "" ->
        {:error, :unknown}

      String.upcase(line) |> String.starts_with?("UNKNOWN") ->
        {:error, :unknown}

      true ->
        case String.split(line, "::", parts: 2) do
          [title, artist] ->
            {:ok, %{title: tidy(title), artist: nilify(tidy(artist))}}

          [title] ->
            # Model ignored the separator; keep the title rather than lose it.
            {:ok, %{title: tidy(title), artist: nil}}
        end
    end
    |> case do
      {:ok, %{title: ""}} -> {:error, :unknown}
      other -> other
    end
  end

  defp tidy(s) do
    s
    |> String.trim()
    |> String.replace(~r/^["'`*]+|["'`*]+$/u, "")
    |> String.trim()
  end

  defp nilify(""), do: nil
  defp nilify(s), do: if(String.upcase(s) == "UNKNOWN", do: nil, else: s)
end
