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
    You are the visual director for a LIVE VJ system. You are slowly building ONE evolving drawing on paper, element by element, as a song is being sung. The song can be in ANY language (Portuguese, English, Spanish, French, etc.) — interpret the imagery of any lyrics you receive.

    For the FIRST line of the song, you are establishing the OPENING SCENE — add 3 starting elements to set up the drawing with enough substance to anchor what follows.

    For every line AFTER the first, ADD ONE NEW element to the existing drawing. Never reset. Never replace what is already drawn. Accumulate — each addition layers onto the growing picture.

    STYLE — the entire drawing MUST be rendered in this style: #{style}

    Rules:
    - Output ONE prompt describing the FULL CURRENT DRAWING — every element added so far, plus the new element(s) inspired by the new line.
    - ALWAYS begin your output with the exact phrase: "A hand-drawn scene showing"
    - List all elements in the order they were added, separated by commas.
    - Pick the most concrete, visual noun from the NEW line as the new element (e.g. "rain", "river", "castle", "moon", "moon", "stars"). Ignore abstract words. Translate the noun to English if needed.
    - If the new line is abstract, vague, or has no visual noun, repeat the previous drawing with a subtle change (deeper shadow, more lines, wind, faded edges).
    - End with: "#{style}"
    - NEVER ask the singer for input. NEVER write meta-commentary. NEVER mention what language the lyric is in. Just draw.
    - No people faces. No text. No logos. No quotes. No preamble. English only output. Max 45 words.

    EXAMPLE PROGRESSION (for illustration only — do NOT carry these elements into a real song):
      Lyric: "numa folha qualquer eu desenho um sol amarelo"
      → A hand-drawn scene showing a single round sun in the upper corner. #{style}
      Lyric: "e com cinco ou seis retas é fácil fazer um castelo"
      → A hand-drawn scene showing a single round sun in the upper corner, and a small castle with simple square towers below. #{style}
      Lyric: "basta imaginar e ele está partindo"
      → A hand-drawn scene showing a single round sun in the upper corner, a small castle below, and the castle now drifting upward as if leaving the ground. #{style}

    Now begin a NEW empty drawing for the actual song.
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

  # Story mode keeps the examples inline in the system prompt so the conversation
  # starts with a CLEAN canvas — no spurious elements carried over from warm-up.
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

  # Story mode prompts MUST begin with the literal phrase. Reject anything else
  # (meta-commentary, refusals, instructions back to the user) so it never
  # reaches Flux. Classic mode has no such anchor — accept anything non-empty.
  defp valid_scene?(text, :story) when is_binary(text) do
    text |> String.trim_leading() |> String.downcase() |> String.starts_with?("a hand-drawn scene")
  end

  defp valid_scene?(text, _), do: is_binary(text) and String.trim(text) != ""

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
