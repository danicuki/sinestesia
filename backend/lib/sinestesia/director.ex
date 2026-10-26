defmodule Sinestesia.Director do
  @moduledoc """
  Multi-turn visual director.

  Maintains a conversation with the LLM across the entire singing session.
  Each new user message is a fresh line of lyrics; the assistant responds with
  ONE visual prompt for that line, building narrative continuity across turns.

  Provider via `DIRECTOR_PROVIDER`:
    "zerog"  → verifiable, TEE-sealed inference on the 0G Compute Network
               (via the local sidecar, `zerog/`), receipt shown on screen
    "gemma"  → local Ollama (`OLLAMA_MODEL`, default Gemma 4 12B)
    "gemini" → Google Gemini API (`GEMINI_MODEL`, default 3.1 Flash-Lite)
    "haiku"  → Anthropic API (`ANTHROPIC_MODEL`, default Claude Haiku 4.5)
    "openai" → OpenAI API (`OPENAI_MODEL`, default GPT-6 Luna)

  On primary failure, falls through to remaining providers (in the order:
  primary → gemma → gemini → haiku, deduped). This keeps a live show resilient:
  when 0G is the primary, a hiccup silently falls back to local Gemma so the
  visuals never stall — and the on-screen receipt reflects which one ran.

  Every provider is called with thinking switched off, or as far down as its
  model allows: on stage the model answers, it does not deliberate. The
  per-model switch is `thinking_candidates/2`; `mix sinestesia.bench.director`
  measures the very call this module makes (`complete/3`).
  """
  require Logger

  @typedoc "A Director backend, as `DIRECTOR_PROVIDER` names it."
  @type provider :: :gemma | :gemini | :haiku | :openai | :zerog

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
  def scene_window do
    case Integer.parse(System.get_env("SCENE_WINDOW", "5")) do
      {n, _} when n > 1 -> n
      _ -> 5
    end
  end

  @default_element_words "4-12"

  @doc """
  How long a compose-mode `NEW:` element may be, in words ("4-12").

  What is worth asking for depends on who listens downstream: the local SDXL
  sidecar hears 77 CLIP tokens of element + style and drops the head, Flux (T5)
  and Nano Banana take whole paragraphs. Longer elements cost output tokens,
  and on a local model output tokens cost time — measure before raising it
  (`mix sinestesia.bench.director --words 30-45`), and raise `DIRECTOR_MAX_TOKENS`
  with it. Anything that is not `min-max` falls back to the default.
  """
  def element_words do
    spec = System.get_env("DIRECTOR_ELEMENT_WORDS", @default_element_words) |> String.trim()
    if Regex.match?(~r/\A\d+-\d+\z/, spec), do: spec, else: @default_element_words
  end

  def default_element_words, do: @default_element_words

  defp system_prompt(style, :classic) do
    """
    You are the visual director for a LIVE VJ system accompanying a singer (any language).

    The song is happening in real time. The user will send you NEW LINES of lyrics, one message at a time. For EACH new line, reply with ONE short visual prompt for that line.

    Build narrative continuity: remember what came before so the visuals evolve rather than reset. Vary your imagery — never repeat the same elements twice in a row unless the lyrics repeat.

    STYLE — every prompt MUST render in this style: #{style}

    Rules:
    - LEAD with the concrete imagery from the NEW line: landscape, objects, weather, motion.
    - Figurative lines are feelings, not objects: never depict a metaphor's noun literally — translate the emotion into the scene's light, weather and motion instead.
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

    NEW: <one concrete element, #{element_words()} words, purely visual> | POS: <position>
    ATMOS: <one subtle whole-scene atmospheric shift, 4-10 words>

    POS is exactly one of: top-left, top, top-right, left, center, right, bottom-left, bottom, bottom-right.

    Rules:
    - Use NEW whenever the line names anything drawable: object, landscape, weather, animal, plant, vehicle — or a PERSON. Translate it to English.
    - PEOPLE ARE WELCOME and should be painted when the lyrics are about them: as stylized full-body figures or silhouettes with a pose, clothing and color that express the lyric. Never close-up faces, never photorealistic portraits.
    - When the lyric describes a type or quality of person ("mulher atrevida", "solteira feliz"), paint ONE distinct figure embodying it — each new type is a NEW different figure, so the picture becomes a gallery.
    - ATMOS only when there is truly nothing to draw (pure feelings, time passing) or when the line just repeats imagery already painted.
    - METAPHORS ARE NOT OBJECTS: when a line uses imagery figuratively ("queria que a verdade fosse como um fruto" is longing, not fruit; "fosse como um doce" is tenderness, not honey), do NOT draw the metaphor's noun — express the feeling through what is already painted (light, weather, a figure's posture) via ATMOS, or add an element that belongs to the song's WORLD. Draw a noun only when the song actually places it in its world; a genuinely visual song ("eu desenho um sol amarelo") is drawn as written.
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
    - METAPHORS ARE NOT OBJECTS: a figurative line ("queria que a verdade fosse como um fruto" = longing, not fruit) must NOT contribute the metaphor's noun — express the feeling through the existing scene (light, weather, posture) or an element of the song's WORLD. Draw a noun only when the song truly places it; a genuinely visual song ("eu desenho um sol amarelo") is drawn as written.
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

  # Two retries at a quarter second covers the observed warm-up window with
  # room to spare; beyond that it is a real failure and the chain should move
  # on rather than stall a frame the singer is already past.
  @pool_warmup_retries 2
  @pool_warmup_ms 250
  @haiku_timeout_ms 3_000
  @openai_timeout_ms 3_000
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

  Requires a provider that can actually inpaint. A `NEW: … | POS: …` delta is
  meaningless to anything else: with no mask and no input image it becomes the
  *whole* prompt for an independent render, so the song turns into a series of
  isolated objects — a sun, a hand, an umbrella — none of them sharing a canvas.
  Google, Cloudflare and Pollinations can't inpaint, so they get the
  scene-list prompt instead, which carries the accumulated scene and the style.
  """
  def compose? do
    mode() == :story and System.get_env("COMPOSE_MODE", "inpaint") != "global" and
      Sinestesia.ImageGen.render_mode() != :t2i and
      Sinestesia.ImageGen.supports?(:inpaint)
  end

  @placements ~w(top-left top top-right left center right bottom-left bottom bottom-right)

  @doc "The nine positions a compose-mode `POS:` may name."
  def placements, do: @placements

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

        %{
          kind: :new,
          element: String.trim(element),
          placement: if(pos in @placements, do: pos, else: "center")
        }

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
        content:
          "low cracked sky pouring sheets of rain onto bare earth, mud splashing upward. #{style}"
      }
    ]
  end

  # Story mode keeps the format examples inline in the system prompt (not as
  # conversation turns) so the conversation starts on a CLEAN canvas — nothing
  # the model treats as "already drawn", avoiding spurious "a second sun" when
  # the real song opens on imagery similar to an example.
  defp warmup(_style, :story), do: []

  @doc """
  Returns the initial conversation (system + warm-up examples) for the given style.

  `prompt: :compose | :global` pins the story-mode prompt instead of resolving
  it from the image provider's capabilities — the bench measures the compose
  contract whatever image provider the box happens to be set up with.
  """
  def init_conversation(style \\ nil, opts \\ []) do
    style = sanitize_style(style || default_style())

    case Keyword.get(opts, :prompt) do
      nil ->
        m = mode()
        [%{role: "system", content: system_prompt(style, m)} | warmup(style, m)]

      :compose ->
        [%{role: "system", content: compose_story_prompt()}]

      :global ->
        [%{role: "system", content: global_story_prompt(style)}]
    end
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
      "anthropic" -> :haiku
      "openai" -> :openai
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

  defp try_chain(chain, messages), do: try_chain(chain, messages, @pool_warmup_retries)

  defp try_chain([], _messages, _warmups), do: {:error, :all_directors_failed}

  # Finch answers `:pool_not_available` while an HTTP/2 pool is still coming
  # up: the pool supervisor exists but no connection has registered yet
  # (Finch.Pool.Manager.maybe_start_pool -> :not_ready). It shows up on the
  # first BURST of concurrent calls to a host — the look-ahead fires the eager
  # bootstrap and a depth-3 prerender chain within milliseconds of each other,
  # so several requests race one cold pool — and clears in well under a
  # second. Falling through on it would trade the operator's chosen model for
  # a weaker one over a transient race, and silently change who directed the
  # frame, so retry the SAME provider first.
  defp try_chain([p | _] = chain, messages, warmups)
       when warmups > 0 do
    case complete(p, messages) do
      {:error, %Req.HTTPError{reason: :pool_not_available}} ->
        Logger.debug("director #{p}: connection pool still warming; retrying")
        Process.sleep(@pool_warmup_ms)
        try_chain(chain, messages, warmups - 1)

      result ->
        handle_result(result, chain, messages, warmups)
    end
  end

  defp try_chain([p | _] = chain, messages, warmups) do
    handle_result(complete(p, messages), chain, messages, warmups)
  end

  defp handle_result(result, [p | rest], messages, warmups) do
    case result do
      {:ok, prompt, meta} ->
        # Record which provider AND model actually answered — the chain falls
        # through on failure, and 0G picks its own model — so the provenance
        # record names the real one, never the configured one.
        note_model(p, meta)
        {:ok, prompt}

      {:error, :no_key} ->
        try_chain(rest, messages, warmups)

      {:error, reason} ->
        Logger.warning("director #{p} failed (#{inspect(reason)}); trying next")
        try_chain(rest, messages, warmups)
    end
  end

  @doc """
  Which provider/model actually produced the last Director prompt in this process.

  Returns `%{provider: "gemini", model: "gemini-3.1-flash-lite"}`. Read by the
  pipeline for the on-chain provenance record: naming the *configured* provider
  would be wrong whenever the chain fell through to a fallback.
  """
  def last_model, do: Process.get(:director_model)

  defp note_model(provider, %{model: model}) do
    Process.put(:director_model, %{provider: to_string(provider), model: model})
    :ok
  end

  @doc """
  The model `provider` is configured to call. Not necessarily what answered a
  given turn — that is `last_model/0`, and the two differ in exactly the cases
  the provenance record cares about.
  """
  @spec configured_model(provider()) :: String.t()
  def configured_model(:gemma),
    do: Keyword.get(Application.fetch_env!(:sinestesia, :config), :ollama_model)

  def configured_model(:gemini), do: System.get_env("GEMINI_MODEL", "gemini-3.1-flash-lite")
  def configured_model(:haiku), do: System.get_env("ANTHROPIC_MODEL", "claude-haiku-4-5")
  def configured_model(:openai), do: System.get_env("OPENAI_MODEL", "gpt-6-luna")
  def configured_model(:zerog), do: "(chosen by the 0G sidecar)"

  @doc "The live budget for one turn of `provider`, in ms — past it the chain moves on."
  @spec timeout_ms(provider()) :: pos_integer()
  def timeout_ms(:gemma), do: @gemma_timeout_ms
  def timeout_ms(:gemini), do: @gemini_timeout_ms
  def timeout_ms(:haiku), do: @haiku_timeout_ms
  def timeout_ms(:openai), do: @openai_timeout_ms
  def timeout_ms(:zerog), do: @zerog_timeout_ms

  ## Providers

  @doc """
  One Director turn against ONE provider, with no fallback.

  Returns `{:ok, text, meta}` or `{:error, reason}`. `meta` says what the reply
  cost: the model that answered; the tokens billed — `in_tokens`, `out_tokens`
  (every output token, reasoning included) and `thinking_tokens` (how many of
  those were reasoning, where the API says); the stop reason (`finish`); which
  thinking setting the API accepted (`thinking`); and, on Ollama, its own split
  of the turn into prompt processing (`prefill_ms`) and generation (`decode_ms`).

  `next_prompt/2` is this plus the fallback chain and output validation. It is
  public so `mix sinestesia.bench.director` measures the request the show really
  sends — same prompt, same caps, same thinking switch — instead of a copy of it.

  Options: `model:` (default `configured_model/1`), `max_tokens:` (default
  `DIRECTOR_MAX_TOKENS`, else 80 on Ollama and 100 elsewhere) and `timeout_ms:`
  (default the live budget, `timeout_ms/1`).
  """
  @spec complete(provider(), [map()], keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def complete(provider, messages, opts \\ [])

  # Verifiable inference on the 0G Compute Network via the local sidecar
  # (`zerog/`), which speaks OpenAI's chat-completions shape and attaches a
  # `verification` receipt (provider, model, chatId, TEE-verified bool). We stash
  # that receipt so the pipeline can put it on screen next to the frame it made.
  def complete(:zerog, messages, opts) do
    url = System.get_env("ZEROG_SIDECAR_URL", "http://127.0.0.1:8788") <> "/v1/chat/completions"
    body = %{messages: messages, temperature: 0.8, max_tokens: max_tokens(:zerog, opts)}

    case Req.post(url, json: body, receive_timeout: timeout(:zerog, opts), retry: false) do
      {:ok,
       %{
         status: 200,
         body: %{"choices" => [%{"message" => %{"content" => content}} = choice | _]} = resp
       }}
      when is_binary(content) and byte_size(content) > 0 ->
        receipt = Map.get(resp, "verification")
        Sinestesia.Verifiability.put(receipt)

        model =
          case receipt do
            %{"model" => m} when is_binary(m) -> m
            _ -> "0g-compute"
          end

        {:ok, clean(content), meta(:zerog, model, nil, chat_usage(resp, choice))}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:empty_response, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:bad_status, status, api_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def complete(:gemma, messages, opts) do
    cfg = Application.fetch_env!(:sinestesia, :config)
    url = Keyword.fetch!(cfg, :ollama_url) <> "/api/chat"
    model = opts[:model] || Keyword.fetch!(cfg, :ollama_model)

    with_thinking(:gemma, model, fn think ->
      body =
        %{
          model: model,
          stream: false,
          options: %{temperature: 0.8, num_predict: max_tokens(:gemma, opts)},
          messages: messages
        }
        |> put_if(:think, think)

      case Req.post(url, json: body, receive_timeout: timeout(:gemma, opts), retry: false) do
        {:ok, %{status: 200, body: %{"message" => %{"content" => content}} = resp}}
        when is_binary(content) and byte_size(content) > 0 ->
          {:ok, clean(content), meta(:gemma, model, think, ollama_usage(resp))}

        {:ok, %{status: 200, body: body}} ->
          {:error, {:empty_response, body}}

        {:ok, %{status: status, body: body}} ->
          {:error, {:bad_status, status, api_error(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def complete(:gemini, messages, opts) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    with {:ok, key} <- key(cfg, :google_api_key) do
      # Gemini wants systemInstruction separately + alternating user/model contents
      {system, turns} = split_system(messages)

      contents =
        Enum.map(turns, fn %{role: role, content: content} ->
          %{role: gemini_role(role), parts: [%{text: content}]}
        end)

      model = opts[:model] || configured_model(:gemini)

      url =
        "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{key}"

      with_thinking(:gemini, model, fn thinking ->
        body = %{
          systemInstruction: %{parts: [%{text: system || ""}]},
          contents: contents,
          generationConfig:
            %{temperature: 0.8, maxOutputTokens: max_tokens(:gemini, opts)}
            |> put_if(:thinkingConfig, thinking)
        }

        case Req.post(url, json: body, receive_timeout: timeout(:gemini, opts), retry: false) do
          {:ok, %{status: 200, body: resp}} ->
            case gemini_text(resp) do
              text when is_binary(text) and byte_size(text) > 0 ->
                {:ok, clean(text), meta(:gemini, model, thinking, gemini_usage(resp))}

              _ ->
                {:error, {:empty_response, gemini_usage(resp).finish || resp["promptFeedback"]}}
            end

          {:ok, %{status: status, body: body}} ->
            {:error, {:bad_status, status, api_error(body)}}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  def complete(:haiku, messages, opts) do
    cfg = Application.fetch_env!(:sinestesia, :config)

    with {:ok, key} <- key(cfg, :anthropic_api_key) do
      # Anthropic also wants system separately
      {system, turns} = split_system(messages)
      model = opts[:model] || configured_model(:haiku)
      headers = [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}]

      with_thinking(:haiku, model, fn thinking ->
        body =
          %{
            model: model,
            max_tokens: max_tokens(:haiku, opts),
            system: system || "",
            messages: turns
          }
          |> Map.merge(thinking || %{})

        case Req.post("https://api.anthropic.com/v1/messages",
               json: body,
               headers: headers,
               receive_timeout: timeout(:haiku, opts),
               retry: false
             ) do
          {:ok, %{status: 200, body: %{"content" => blocks} = resp}} when is_list(blocks) ->
            # With adaptive thinking the first block is the thinking, not the answer.
            case Enum.find_value(blocks, fn
                   %{"type" => "text", "text" => t} -> t
                   _ -> nil
                 end) do
              text when is_binary(text) and byte_size(text) > 0 ->
                {:ok, clean(text), meta(:haiku, model, thinking, anthropic_usage(resp))}

              _ ->
                {:error, {:empty_response, resp["stop_reason"]}}
            end

          {:ok, %{status: status, body: body}} ->
            {:error, {:bad_status, status, api_error(body)}}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  @openai_api "https://api.openai.com/v1"

  # Chat Completions — the shape the 0G sidecar speaks too. No temperature:
  # the GPT-6 family rejects sampling knobs at several reasoning efforts with
  # a 400, and a 400 mid-song costs a frame; the prompt carries the variety.
  def complete(:openai, messages, opts) do
    cfg = Application.fetch_env!(:sinestesia, :config)
    base = openai_base_url()

    with {:ok, headers} <- openai_headers(cfg, base) do
      model = opts[:model] || configured_model(:openai)

      with_thinking(:openai, model, fn reasoning ->
        body =
          %{model: model, messages: messages, max_completion_tokens: max_tokens(:openai, opts)}
          |> Map.merge(reasoning || %{})

        case Req.post(base <> "/chat/completions",
               json: body,
               headers: headers,
               receive_timeout: timeout(:openai, opts),
               retry: false
             ) do
          {:ok,
           %{
             status: 200,
             body: %{"choices" => [%{"message" => %{"content" => content}} = choice | _]} = resp
           }}
          when is_binary(content) and byte_size(content) > 0 ->
            # The API names the exact snapshot it ran ("gpt-6-luna-2026-05-18").
            answered = if is_binary(resp["model"]), do: resp["model"], else: model
            {:ok, clean(content), meta(:openai, answered, reasoning, chat_usage(resp, choice))}

          {:ok, %{status: 200, body: body}} ->
            {:error, {:empty_response, get_in(body, ["choices", Access.at(0), "finish_reason"])}}

          {:ok, %{status: status, body: body}} ->
            {:error, {:bad_status, status, api_error(body)}}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  @doc """
  Where the `openai` provider posts: OpenAI itself, unless `OPENAI_BASE_URL`
  names another endpoint that speaks the same shape — a local proxy in front of
  a Codex/ChatGPT login, OpenRouter, a vLLM box. Trailing slash dropped.
  """
  def openai_base_url do
    case System.get_env("OPENAI_BASE_URL", "") |> String.trim() |> String.trim_trailing("/") do
      "" -> @openai_api
      url -> url
    end
  end

  # OpenAI itself needs the key. A proxy holds its own credentials, so against
  # any other endpoint a missing key just means no Authorization header.
  defp openai_headers(cfg, base) do
    case {key(cfg, :openai_api_key), base} do
      {{:ok, key}, _} -> {:ok, [{"authorization", "Bearer " <> key}]}
      {{:error, :no_key}, @openai_api} -> {:error, :no_key}
      {{:error, :no_key}, _proxy} -> {:ok, []}
    end
  end

  ## Thinking

  @doc """
  How to switch `model`'s thinking off, most-off first; `nil` means "send no
  thinking field at all" (the model's own default).

  The thinking switch is the one request field every vendor keeps changing —
  Gemini went `thinkingBudget: 0` → `thinkingLevel`, 3.8 Flash and Gemini 4
  have no `minimal` at all; Anthropic went `enabled`/`disabled` → `adaptive` +
  `output_config.effort`, Sonnet 5.5's floor is `between_tools`, Opus 5.5
  cannot stop thinking; OpenAI's `reasoning_effort: "none"` exists on Luna but
  400s on Astra and 6.1 Sol — and the one a wrong value fails on with a 400.
  `complete/3` tries these in order and remembers, per model, the first the API
  accepted, so a retry is paid once per boot rather than once per turn.
  """
  @spec thinking_candidates(provider(), String.t()) :: [term()]
  def thinking_candidates(:gemma, _model), do: [false, nil]

  def thinking_candidates(:gemini, model) do
    cond do
      # 2.5 and 3.1 take a token budget; 0 turns thinking off.
      String.starts_with?(model, ["gemini-2.5", "gemini-3.1"]) -> [%{thinkingBudget: 0}, nil]
      # 3.8 Flash and Gemini 4 always reason; "low" is their floor.
      String.starts_with?(model, ["gemini-3.8", "gemini-4"]) -> [%{thinkingLevel: "low"}, nil]
      # 3.5 Flash-Lite, 3.6 Flash: levels, with a real "minimal".
      true -> [%{thinkingLevel: "minimal"}, %{thinkingLevel: "low"}, nil]
    end
  end

  def thinking_candidates(:haiku, model) do
    cond do
      String.starts_with?(model, "claude-haiku-5") ->
        [%{thinking: %{type: "disabled"}}, %{thinking: %{type: "between_tools"}}, nil]

      String.starts_with?(model, "claude-sonnet-5") ->
        [%{thinking: %{type: "between_tools"}}, %{thinking: %{type: "disabled"}}, nil]

      String.starts_with?(model, ["claude-opus-5", "claude-fable", "claude-mythos"]) ->
        [%{output_config: %{effort: "low"}}, nil]

      # Haiku 4.5 and older never think unless asked to.
      true ->
        [nil]
    end
  end

  def thinking_candidates(:openai, model) do
    if String.starts_with?(model, ["gpt-6-astra", "gpt-6.1"]),
      do: [%{reasoning_effort: "low"}, nil],
      else: [
        %{reasoning_effort: "none"},
        %{reasoning_effort: "minimal"},
        %{reasoning_effort: "low"},
        nil
      ]
  end

  def thinking_candidates(:zerog, _model), do: [nil]

  @doc """
  Whether `model` reasons before every answer no matter what we send — the
  models whose lowest setting is still a `low`. Their output cap must leave
  room for the thinking (it counts), and their latency is not a live latency.
  """
  @spec always_thinks?(provider(), String.t()) :: boolean()
  def always_thinks?(provider, model) do
    case thinking_candidates(provider, model) do
      [%{thinkingLevel: "low"} | _] -> true
      [%{output_config: _} | _] -> true
      [%{reasoning_effort: "low"} | _] -> true
      _ -> false
    end
  end

  defp with_thinking(provider, model, request) do
    key = {__MODULE__, :thinking, provider, model}

    candidates =
      case :persistent_term.get(key, :unknown) do
        :unknown -> thinking_candidates(provider, model)
        known -> [known]
      end

    attempt(candidates, key, request)
  end

  defp attempt([cfg | rest], key, request) do
    case request.(cfg) do
      {:ok, _, _} = ok ->
        if :persistent_term.get(key, :unknown) != cfg, do: :persistent_term.put(key, cfg)
        ok

      {:error, {:bad_status, 400, message}} = error ->
        # A remembered setting that stopped working is forgotten, so the next
        # turn climbs the ladder again instead of failing forever.
        :persistent_term.erase(key)

        case rest do
          [] ->
            error

          [next | _] ->
            Logger.info(
              "[director] #{provider_of(key)} rejected #{inspect(cfg)} (#{message}); trying #{inspect(next)}"
            )

            attempt(rest, key, request)
        end

      error ->
        error
    end
  end

  defp provider_of({_, _, provider, model}), do: "#{provider} #{model}"

  ## Usage

  defp meta(provider, model, thinking, usage) do
    %{
      provider: provider,
      model: model,
      thinking: thinking,
      in_tokens: nil,
      out_tokens: nil,
      thinking_tokens: nil,
      finish: nil,
      prefill_ms: nil,
      decode_ms: nil,
      load_ms: nil
    }
    |> Map.merge(usage)
  end

  # OpenAI shape (OpenAI itself, the 0G sidecar): completion_tokens already
  # includes the reasoning tokens.
  defp chat_usage(resp, choice) do
    u = resp["usage"] || %{}

    %{
      in_tokens: u["prompt_tokens"],
      out_tokens: u["completion_tokens"],
      thinking_tokens: get_in(u, ["completion_tokens_details", "reasoning_tokens"]),
      finish: choice["finish_reason"]
    }
  end

  # Gemini bills thoughts as output but counts them apart from the answer.
  defp gemini_usage(resp) do
    u = resp["usageMetadata"] || %{}
    thoughts = u["thoughtsTokenCount"]

    out =
      case u["candidatesTokenCount"] do
        n when is_integer(n) -> n + (thoughts || 0)
        _ -> nil
      end

    %{
      in_tokens: u["promptTokenCount"],
      out_tokens: out,
      thinking_tokens: thoughts,
      finish: get_in(resp, ["candidates", Access.at(0), "finishReason"])
    }
  end

  # Anthropic's output_tokens include thinking; it does not say how many.
  defp anthropic_usage(resp) do
    u = resp["usage"] || %{}
    %{in_tokens: u["input_tokens"], out_tokens: u["output_tokens"], finish: resp["stop_reason"]}
  end

  # Ollama reports its own clock: prompt processing, generation and model load, in ns.
  defp ollama_usage(resp) do
    ms = fn k ->
      case resp[k] do
        n when is_number(n) -> n / 1_000_000
        _ -> nil
      end
    end

    %{
      in_tokens: resp["prompt_eval_count"],
      out_tokens: resp["eval_count"],
      finish: resp["done_reason"],
      prefill_ms: ms.("prompt_eval_duration"),
      decode_ms: ms.("eval_duration"),
      load_ms: ms.("load_duration")
    }
  end

  # The first part that is an answer, not a thought. A candidate that spent its
  # whole output budget deliberating has no parts at all.
  defp gemini_text(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]})
       when is_list(parts) do
    Enum.find_value(parts, fn
      %{"thought" => true} -> nil
      %{"text" => t} when is_binary(t) -> t
      _ -> nil
    end)
  end

  defp gemini_text(_), do: nil

  ## Helpers

  @default_max_tokens %{gemma: 80, gemini: 100, haiku: 100, openai: 100, zerog: 100}

  # Room for a 4-12 word element plus its position; the cap only bites when
  # the model is already off-format. `DIRECTOR_ELEMENT_WORDS` above the
  # default needs `DIRECTOR_MAX_TOKENS` raised with it.
  defp max_tokens(provider, opts) do
    opts[:max_tokens] ||
      case Integer.parse(System.get_env("DIRECTOR_MAX_TOKENS", "")) do
        {n, _} when n > 0 -> n
        _ -> @default_max_tokens[provider]
      end
  end

  defp timeout(provider, opts), do: opts[:timeout_ms] || timeout_ms(provider)

  defp key(cfg, name) do
    case Keyword.get(cfg, name) do
      k when is_binary(k) and k != "" -> {:ok, k}
      _ -> {:error, :no_key}
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  # One line a person at the sound desk can read, whatever shape the vendor's
  # error document takes.
  defp api_error(%{"error" => %{"message" => m}}) when is_binary(m), do: String.slice(m, 0, 300)
  defp api_error(%{"error" => m}) when is_binary(m), do: String.slice(m, 0, 300)
  defp api_error(body), do: body |> inspect() |> String.slice(0, 300)

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
