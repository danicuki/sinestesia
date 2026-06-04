import Config

env_path = Path.expand("../../.env", __DIR__)

if File.exists?(env_path) do
  env_path
  |> File.stream!()
  |> Enum.each(fn line ->
    case String.trim(line) do
      "" -> :ok
      "#" <> _ -> :ok
      kv ->
        case String.split(kv, "=", parts: 2) do
          [k, v] ->
            key = String.trim(k)
            val = v |> String.trim() |> String.trim("\"")
            if val != "", do: System.put_env(key, val)

          _ -> :ok
        end
    end
  end)
end

get_env = fn key, default ->
  case System.get_env(key) do
    nil -> default
    "" -> default
    v -> v
  end
end

config :sinestesia, :config,
  port: String.to_integer(get_env.("PORT", "4000")),
  elevenlabs_api_key: System.get_env("ELEVENLABS_API_KEY"),
  deepgram_api_key: System.get_env("DEEPGRAM_API_KEY"),
  fal_api_key: System.get_env("FAL_API_KEY"),
  google_api_key: System.get_env("GOOGLE_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  ollama_url: get_env.("OLLAMA_URL", "http://localhost:11434"),
  ollama_model: get_env.("OLLAMA_MODEL", "gemma4:12b-mlx")
