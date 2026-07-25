defmodule Sinestesia.Director do
  @moduledoc """
  Multi-turn visual director.

  Maintains a conversation with the LLM across the entire singing session.
  Each new user message is a fresh line of lyrics; the assistant responds with
  ONE visual prompt for that line, building narrative continuity across turns.

  Provider via `DIRECTOR_PROVIDER`:
    "zerog"  → verifiable, TEE-sealed inference on the 0G Compute Network
               (via the local sidecar, `zerog/`), receipt shown on screen
    "gemma"  → Gemma 4 12B via local Ollama
    "gemini" → Google Gemini 2.5 Flash via API
    "haiku"  → Claude Haiku 4.5 via Anthropic API

  On primary failure, falls through to remaining providers (in the order:
  primary → gemma → gemini → haiku, deduped). This keeps a live show resilient:
  when 0G is the primary, a hiccup silently falls back to local Gemma so the
  visuals never stall — and the on-screen receipt reflects which one ran.
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

  # How many scene elements the Director may re-list per prompt. The window is
  # the song's VISUAL memory: elements inside it stay textually anchored
  # (crisp, persistent); elements that fall out live on only through img2img
  # inheritance and naturally fade over the following frames. Big enough for
  # context, small enough that recent lyrics carry the most weight.
  defp scene_window do
    case Integer.parse(System.get_env("SCENE_WINDOW", "5")) do
      {n, _} when n > 1 -> n
      _ -> 5
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

  # Story mode: NO style words in the Director's output. The backend stamps
  # the operator's style onto the FIRST image (and after a style change) only;
  # from then on img2img inherits it visually. Repeating the style text every
  # frame re-applies it to the whole canvas each cycle and drags the image
  # toward the style's fixed point (e.g. "geometric shapes" → flat polygons by
  # frame 19). Dropping it also frees the CLIP token budget for the scene list.
  defp system_prompt(style, :story) do
    if compose?(), do: compose_story_prompt(), else: global_story_prompt(style)
  end

  defp compose_story_prompt do
    """
    You are the visual director for a LIVE VJ system painting ONE evolving picture for a song sung live, in ANY language (Portuguese, English, Spanish, French, etc.) — interpret the imagery of whatever lyrics you receive.

    The picture grows element by element: each reply paints ONE new thing onto the existing canvas. For EACH lyric line, reply with EXACTLY ONE line in ONE of these two formats:

    NEW: <one concrete element, 4-12 words, purely visual> | POS: <position>
    ATMOS: <one subtle whole-scene atmospheric shift, 4-10 words>

    POS is exactly one of: top-left, top, top-right, left, center, right, bottom-left, bottom, bottom-right.

    Rules:
    - Use NEW whenever the line names anything drawable: object, landscape, weather, animal, plant, vehicle — or a PERSON. Translate it to English.
    - PEOPLE ARE WELCOME and should be painted when the lyrics are about them: as stylized full-body figures or silhouettes with a pose, clothing and color that express the lyric. Never close-up faces, never photorealistic portraits.
    - When the lyric describes a type or quality of person ("mulher atrevida", "solteira feliz"), paint ONE distinct figure embodying it — each new type is a NEW different figure, so the picture becomes a gallery.
    - ATMOS only when there is truly nothing to draw (pure feelings, time passing) or when the line just repeats imagery already painted.
    - Name elements plainly ("a sailboat", "a yellow sun"). NEVER use minimizers like "small", "tiny", "distant", "in the background" — but don't force size words either.
    - Choose a POS likely to be EMPTY space. VARY the position across the song — never repeat the previous POS.
    - The FIRST line of a song is always NEW, POS top or center.
    - Do NOT mention any art style, medium, technique or artist — content only.
    - NEVER ask the singer for input. NEVER write meta-commentary. No text. No logos. No quotes. English only.

    EXAMPLES (illustration only — these are NOT drawn, start fresh for the real song):
      Lyric: "eu desenho um sol amarelo" → NEW: a round yellow sun | POS: top
      Lyric: "é fácil fazer um castelo" → NEW: a castle with tall towers | POS: right
      Lyric: "já tive mulheres de todas as cores" → NEW: a woman dancing in a flowing red dress | POS: left
      Lyric: "do tipo acanhada" → NEW: a shy woman figure hiding under a wide straw hat | POS: bottom-right
      Lyric: "molha o céu, molha o chão" → NEW: heavy diagonal rain streaks | POS: top-left
      Lyric: "vai voando" → ATMOS: a gentle sense of upward drift
    """
  end

  defp global_story_prompt(_style) do
    window = scene_window()

    """
    You are the visual director for a LIVE VJ system painting ONE evolving picture for a song sung live, in ANY language (Portuguese, English, Spanish, French, etc.) — interpret the imagery of whatever lyrics you receive.

    Each new image is painted ON TOP of the previous one. For EACH lyric line, reply with ONE compact comma-separated list: the #{window} MOST RECENT scene elements (1-3 words each, older first), ENDING with the NEW element this line adds.

    Rules:
    - HARD LIMIT: never list more than #{window} elements. When the scene has more, DROP the oldest from your reply — dropped elements remain in the picture by themselves and slowly fade, which is desired.
    - The NEW element is the concrete imagery of the current line: a person, animal, object, landscape, weather, motion. Translate it to English.
    - THE SUBJECT OUTRANKS INCIDENTAL OBJECTS: the character the line is about ("o pato", "a menina") matters more than the things around it ("o caneco"). The song's protagonist enters the scene FIRST and STAYS in your list as long as the lyrics keep referring to it — never let it slide out of the window while it's still the topic.
    - PEOPLE AND ANIMALS ARE WELCOME: draw them as stylized full-body figures with a pose that expresses the lyric. Never close-up faces, never photorealistic portraits.
    - Give the NEW element a placement into empty space (e.g. "a castle on the right"). Don't force size words.
    - The FIRST line of a song has no scene yet: reply with just the opening element in a wide airy scene.
    - If the line is abstract with no concrete imagery, the new element is a subtle atmospheric shift (deeper shadows, drifting light, wind).
    - Do NOT mention any art style, medium or technique (no "sketch", "painting", "watercolor", artist names) — style is handled elsewhere. Content only.
    - NEVER ask the singer for input. NEVER write meta-commentary. No text. No logos. No quotes. English only. Max 30 words.

    Before answering, silently ask: WHO or WHAT is this line about? That is the protagonist. Then: what does the line say about it (action, quality, surroundings)?

    FORMAT EXAMPLES — one per category, invented lines (these are NOT drawn, start fresh for the real song):
      Animal protagonist: "la tortuga cruza el río" (first line) → a turtle paddling across a wide river
      Person joins: "meu avô fuma seu cachimbo na varanda" → turtle in river, plus an old man smoking a pipe on a porch
      Weather/landscape: "the storm rolls over the hills" → turtle, old man with pipe, plus dark storm clouds over rolling hills
      Abstract line: "et le temps passe lentement" → turtle, old man, storm clouds, plus long slow shadows drifting
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
  # 0G routes inference over the network with an on-chain-signed request. The
  # sidecar now settles/verifies ON-CHAIN IN THE BACKGROUND (off the response
  # path), so the Director only waits for request-signing + inference: ~1.7s warm,
  # ~2.8s cold. 5s leaves comfortable headroom while failing over fast if the
  # provider stalls. (Was 12s, back when settlement blocked the response.)
  @zerog_timeout_ms 5_000

  @doc """
  Compose mode (default): each Director reply is ONE new element + a position,
  rendered by the sidecar as a localized INPAINT — the element is guaranteed
  to materialize and the rest of the canvas is untouched. `COMPOSE_MODE=global`
  falls back to whole-canvas img2img with a scene-list prompt.
  """
  def compose? do
    mode() == :story and System.get_env("COMPOSE_MODE", "inpaint") != "global" and
      Sinestesia.ImageGen.render_mode() != :t2i
  end

  @placements ~w(top-left top top-right left center right bottom-left bottom bottom-right)

  @doc """
  Parses a story-mode compose reply into an image request:

      "NEW: a small castle | POS: right" → %{kind: :new, element: "a small castle", placement: "right"}
      "ATMOS: drifting golden haze"      → %{kind: :atmos, text: "drifting golden haze"}

  Anything unparseable degrades to an atmospheric (global img2img) pass.
  """
  def parse_story(text) do
    case Regex.run(~r/NEW:\s*(.+?)\s*\|\s*POS:\s*([a-zA-Z\-]+)/, text) do
      [_, element, pos] ->
        pos = pos |> String.downcase() |> String.trim()
        %{kind: :new, element: String.trim(element), placement: if(pos in @placements, do: pos, else: "center")}

      nil ->
        # `[^|]` strips trailing junk Gemma sometimes appends ("ATMOS: a
        # heavy haze | POS: center") so it never reaches the image prompt.
        case Regex.run(~r/NEW:\s*([^|]+)/, text) do
          [_, element] ->
            %{kind: :new, element: String.trim(element), placement: "center"}

          nil ->
            case Regex.run(~r/ATMOS:\s*([^|]+)/, text) do
              [_, t] -> %{kind: :atmos, text: String.trim(t)}
              nil -> %{kind: :atmos, text: String.trim(text)}
            end
        end
    end
  end

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

    # A fresh turn: clear any stale 0G receipt so the frontend never shows a
    # verified badge for a frame the fallback providers actually produced. The
    # zerog provider re-populates it on success.
    Sinestesia.Verifiability.put(nil)

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

  def next_prompt(conversation, _), do: {:error, {:empty_line, conversation}}

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

  def provider do
    case System.get_env("DIRECTOR_PROVIDER", "gemma") |> String.downcase() do
      "zerog" -> :zerog
      "0g" -> :zerog
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
        # Record which provider actually answered — the chain falls through on
        # failure, so the configured provider is not necessarily the one that
        # directed this frame. The provenance record must name the real one.
        note_model(p)
        {:ok, prompt}

      {:error, :no_key} ->
        try_chain(rest, messages)

      {:error, reason} ->
        Logger.warning("director #{p} failed (#{inspect(reason)}); trying next")
        try_chain(rest, messages)
    end
  end

  @doc """
  Which provider/model actually produced the last Director prompt in this process.

  Returns `%{provider: "gemini", model: "gemini-3.1-flash-lite"}`. Read by the
  pipeline for the on-chain provenance record: naming the *configured* provider
  would be wrong whenever the chain fell through to a fallback.
  """
  def last_model, do: Process.get(:director_model)

  defp note_model(provider) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    model =
      case provider do
        :zerog ->
          case Sinestesia.Verifiability.last() do
            %{"model" => m} when is_binary(m) -> m
            _ -> "0g-compute"
          end

        :gemma -> Keyword.get(cfg, :ollama_model)
        :gemini -> System.get_env("GEMINI_MODEL", "gemini-3.1-flash-lite")
        :haiku -> "claude-haiku-4-5"
        other -> to_string(other)
      end

    Process.put(:director_model, %{provider: to_string(provider), model: model})
    :ok
  end

  ## Providers

  # Verifiable inference on the 0G Compute Network via the local sidecar
  # (`zerog/`), which speaks OpenAI's chat-completions shape and attaches a
  # `verification` receipt (provider, model, chatId, TEE-verified bool). We stash
  # that receipt so the pipeline can put it on screen next to the frame it made.
  defp call(:zerog, messages) do
    url = System.get_env("ZEROG_SIDECAR_URL", "http://127.0.0.1:8788") <> "/v1/chat/completions"
    body = %{messages: messages, temperature: 0.8, max_tokens: 100}

    case Req.post(url, json: body, receive_timeout: @zerog_timeout_ms, retry: false) do
      {:ok,
       %{
         status: 200,
         body: %{"choices" => [%{"message" => %{"content" => content}} | _]} = resp
       }}
      when is_binary(content) and byte_size(content) > 0 ->
        Sinestesia.Verifiability.put(Map.get(resp, "verification"))
        {:ok, clean(content)}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:empty_response, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:bad_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

        # 3.1 Flash-Lite: 2.5x faster TTFT than 2.5 Flash at same-or-better
        # quality — ~200-400ms per Director turn. NOT the "-preview" variant
        # (discontinued 2026-07-09).
        model = System.get_env("GEMINI_MODEL", "gemini-3.1-flash-lite")

        url =
          "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

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
