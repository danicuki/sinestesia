defmodule Sinestesia.Director do
  @moduledoc """
  Multi-turn visual director.

  Maintains a conversation with the LLM across the entire singing session.
  Each new user message is a fresh line of lyrics; the assistant responds with
  ONE visual prompt for that line, building narrative continuity across turns.

  Provider via `DIRECTOR_PROVIDER`:
    "gemma"  → Gemma 4 12B via local Ollama
    "gemini" → Google Gemini 2.5 Flash via API
    "haiku"  → Claude Haiku 4.5 via Anthropic API

  On primary failure, falls through to remaining providers (in the order:
  primary → gemma → gemini → haiku, deduped).
  """
  require Logger

  @default_style_classic "Brazilian cordel woodcut print, black and white, hatched linework"
  @default_style_story "loose ink sketch on aged paper, sparse hand-drawn linework, sepia tones"

  def default_style do
    case mode() do
      :story -> @default_style_story
      _ -> @default_style_classic
    end
  end

  def mode do
    case System.get_env("IMAGE_MODE", "story") |> String.downcase() do
      "classic" -> :classic
      _ -> :story
    end
  end

  defp system_prompt(style, :classic) do
    """
    You are the visual director for a LIVE VJ system accompanying a singer (any language).

    The song is happening in real time. The user will send you NEW LINES of lyrics, one message at a time. For EACH new line, reply with ONE short visual prompt for that line.

    Build narrative continuity: remember what came before so the visuals evolve rather than reset. Vary your imagery — never repeat the same elements twice in a row unless the lyrics repeat.

    STYLE — every prompt MUST render in this style: #{style}

    Rules:
    - LEAD with the concrete imagery from the NEW line: landscape, objects, weather, motion.
    - End with the literal style note: "#{style}"
    - No people. No faces. No text. No logos. No quotes. No preamble.
    - Output ONE prompt in English, max 22 words.
    """
  end

  defp system_prompt(style, :story) do
    """
    You are the visual director for a LIVE VJ system painting visuals for a song sung live, in ANY language (Portuguese, English, Spanish, French, etc.) — interpret the imagery of whatever lyrics you receive.

    The system keeps ONE evolving picture: each new image is painted ON TOP of the previous one, so elements accumulate by themselves. You do NOT need to repeat or re-list what is already drawn — only describe the NEW thing to add for the current line.

    STYLE — every prompt MUST end with this exact style note: #{style}

    Rules:
    - LEAD with the concrete NEW imagery from this line: an object, landscape, weather, animal, motion (e.g. "a round yellow sun", "a small castle", "rain falling", "a seagull").
    - Translate the imagery to English if the lyric isn't in English.
    - If the line is abstract with no concrete imagery, evoke a subtle atmospheric shift instead (deeper shadows, drifting light, wind, fading edges).
    - Keep it SHORT: at most 15 words before the style note.
    - NEVER ask the singer for input. NEVER write meta-commentary. NEVER mention what language the lyric is in. Just describe the visual.
    - No people's faces. No text. No logos. No quotes. No preamble. English only.
    - End with: #{style}

    FORMAT EXAMPLES (illustration only — these are NOT already drawn, start fresh for the real song):
      Lyric: "molha o céu, molha o chão" → heavy diagonal rain falling over bare earth. #{style}
      Lyric: "águas de março fechando o verão" → a swelling river carrying swirling leaves. #{style}
      Lyric: "o resto é mato" → dense tangled undergrowth spreading across the ground. #{style}
    """
  end

  # Capping breaks Ollama's prefix cache — each cap shifts the conversation
  # window, forcing a full reprocess (~3x slowdown observed at @max_turns=16).
  # Keep it high enough that a normal song (~30-60 lines) never triggers a cap.
  # If you really need to reset, restart the session.
  @max_turns 200
  # First call after server boot has to load the model into memory — can take
  # 4-6s. Subsequent calls are ~1s warm. Setting a generous timeout so the
  # bootstrap call doesn't fall through to Gemini (which is out of credits).
  @gemma_timeout_ms 8_000
  @gemini_timeout_ms 3_000
  @haiku_timeout_ms 3_000

  defp warmup(style, :classic) do
    [
      %{role: "user", content: "águas de março fechando o verão"},
      %{
        role: "assistant",
        content:
          "swelling river beneath heavy diagonal rain lines, scattered leaves swirling on the surface. #{style}"
      },
      %{role: "user", content: "molha o céu, molha o chão"},
      %{
        role: "assistant",
        content: "low cracked sky pouring sheets of rain onto bare earth, mud splashing upward. #{style}"
      }
    ]
  end

  # Story mode keeps the format examples inline in the system prompt (not as
  # conversation turns) so the conversation starts on a CLEAN canvas — nothing
  # the model treats as "already drawn", avoiding spurious "a second sun" when
  # the real song opens on imagery similar to an example.
  defp warmup(_style, :story), do: []

  @doc "Returns the initial conversation (system + warm-up examples) for the given style."
  def init_conversation(style \\ nil) do
    style = sanitize_style(style || default_style())
    m = mode()
    [%{role: "system", content: system_prompt(style, m)} | warmup(style, m)]
  end

  @doc """
  Caps style to 15 words max and strips quotes/control chars so a malicious or
  sloppy frontend can't inject prompt-engineering payloads. 15 is enough room
  for full palette entries (e.g. "loose ink sketch on aged paper, ...") while
  still preventing prompt-injection from sneaking in a paragraph.
  """
  def sanitize_style(nil), do: default_style()
  def sanitize_style(""), do: default_style()

  def sanitize_style(text) when is_binary(text) do
    text
    |> String.replace(~r/["\n\r\t]/, " ")
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(15)
    |> Enum.join(" ")
    |> case do
      "" -> default_style()
      s -> s
    end
  end

  def sanitize_style(_), do: default_style()

  @doc """
  Continues the conversation with a new user line. Returns
  `{:ok, prompt, new_conversation}` on success, `{:error, reason}` on failure.

  When all providers fail, the original conversation is returned unchanged so
  the next call can retry — no garbage gets appended.
  """
  @spec next_prompt([map()], String.t()) ::
          {:ok, String.t(), [map()]} | {:error, term()}
  def next_prompt(conversation, line) when is_binary(line) and line != "" do
    user_msg = %{role: "user", content: line}
    messages = conversation ++ [user_msg]
    primary = provider()
    chain = Enum.uniq([primary, :gemma, :gemini, :haiku])

    case try_chain(chain, messages) do
      {:ok, response} ->
        if valid_scene?(response, mode()) do
          new_conversation =
            (conversation ++ [user_msg, %{role: "assistant", content: response}])
            |> cap_history()

          {:ok, response, new_conversation}
        else
          # The model returned meta-commentary or refused. Don't pollute the
          # conversation with the bad turn — leave history as-is so the next
          # call retries from a clean slate.
          Logger.warning("[director] rejected invalid output: #{inspect(response)}")
          {:error, :invalid_output}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Reject meta-commentary / refusals (e.g. "please provide the first line",
  # "I cannot see...") so garbage never reaches the image model. Concise scene
  # descriptions pass; anything that looks like the model talking to the user fails.
  @refusal_markers [
    "provide the",
    "i cannot",
    "i can't",
    "i need",
    "please provide",
    "as an ai",
    "could you",
    "let me know",
    "i'm sorry",
    "i am sorry"
  ]

  defp valid_scene?(text, _mode) when is_binary(text) do
    trimmed = String.trim(text)
    lower = String.downcase(trimmed)
    trimmed != "" and not Enum.any?(@refusal_markers, &String.contains?(lower, &1))
  end

  defp valid_scene?(_text, _mode), do: false

  def next_prompt(conversation, _), do: {:error, {:empty_line, conversation}}

  def provider do
    case System.get_env("DIRECTOR_PROVIDER", "gemma") |> String.downcase() do
      "gemini" -> :gemini
      "haiku" -> :haiku
      _ -> :gemma
    end
  end

  defp cap_history(conversation) do
    case conversation do
      [system | rest] ->
        # Keep system + last @max_turns * 2 messages (user + assistant pairs)
        kept = Enum.take(rest, -2 * @max_turns)
        [system | kept]

      [] ->
        []
    end
  end

  ## Provider chain

  defp try_chain([], _messages), do: {:error, :all_directors_failed}

  defp try_chain([p | rest], messages) do
    case call(p, messages) do
      {:ok, prompt} ->
        {:ok, prompt}

      {:error, :no_key} ->
        try_chain(rest, messages)

      {:error, reason} ->
        Logger.warning("director #{p} failed (#{inspect(reason)}); trying next")
        try_chain(rest, messages)
    end
  end

  ## Providers

  defp call(:gemma, messages) do
    cfg = Application.fetch_env!(:sinestesia, :config)
    url = Keyword.fetch!(cfg, :ollama_url) <> "/api/chat"

    body = %{
      model: Keyword.fetch!(cfg, :ollama_model),
      stream: false,
      think: false,
      # 80 gives room for ~25 words of content + ~15 tokens of style note
      # without truncating mid-style (which makes Flux miss the style entirely).
      options: %{temperature: 0.8, num_predict: 80},
      messages: messages
    }

    case Req.post(url, json: body, receive_timeout: @gemma_timeout_ms, retry: false) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}}}}
      when is_binary(content) and byte_size(content) > 0 ->
        {:ok, clean(content)}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:empty_response, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:bad_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call(:gemini, messages) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :google_api_key) do
      nil ->
        {:error, :no_key}

      "" ->
        {:error, :no_key}

      key ->
        # Gemini wants systemInstruction separately + alternating user/model contents
        {system, turns} = split_system(messages)

        contents =
          Enum.map(turns, fn %{role: role, content: content} ->
            %{role: gemini_role(role), parts: [%{text: content}]}
          end)

        url =
          "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=#{key}"

        body = %{
          systemInstruction: %{parts: [%{text: system || ""}]},
          contents: contents,
          generationConfig: %{
            temperature: 0.8,
            maxOutputTokens: 100,
            thinkingConfig: %{thinkingBudget: 0}
          }
        }

        case Req.post(url, json: body, receive_timeout: @gemini_timeout_ms, retry: false) do
          {:ok,
           %{
             status: 200,
             body: %{
               "candidates" => [
                 %{"content" => %{"parts" => [%{"text" => text} | _]}} | _
               ]
             }
           }}
          when is_binary(text) and byte_size(text) > 0 ->
            {:ok, clean(text)}

          {:ok, %{status: status, body: body}} ->
            {:error, {:bad_status, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp call(:haiku, messages) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    case Keyword.get(cfg, :anthropic_api_key) do
      nil ->
        {:error, :no_key}

      "" ->
        {:error, :no_key}

      key ->
        # Anthropic also wants system separately
        {system, turns} = split_system(messages)

        body = %{
          model: "claude-haiku-4-5",
          max_tokens: 100,
          system: system || "",
          messages: turns
        }

        headers = [
          {"x-api-key", key},
          {"anthropic-version", "2023-06-01"}
        ]

        case Req.post("https://api.anthropic.com/v1/messages",
               json: body,
               headers: headers,
               receive_timeout: @haiku_timeout_ms,
               retry: false
             ) do
          {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
            {:ok, clean(text)}

          {:ok, resp} ->
            {:error, {:bad_status, resp.status}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  ## Helpers

  defp split_system([%{role: "system", content: s} | rest]), do: {s, rest}
  defp split_system(messages), do: {nil, messages}

  defp gemini_role("assistant"), do: "model"
  defp gemini_role(role), do: role

  defp clean(text) do
    text
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end
end
