# Run this script with: mix run scripts/test_gemini.exs
# It verifies Gemini 2.5 Flash API connectivity and latency.

# Load .env
env_path = Path.expand("../.env", __DIR__)
if File.exists?(env_path) do
  File.stream!(env_path)
  |> Enum.each(fn line ->
    case String.trim(line) do
      "" -> :ok
      "#" <> _ -> :ok
      kv ->
        case String.split(kv, "=", parts: 2) do
          [k, v] ->
            key = String.trim(k)
            val = v |> String.trim() |> String.trim("\"")
            if val != "" and System.get_env(key) in [nil, ""], do: System.put_env(key, val)
          _ -> :ok
        end
    end
  end)
end

key = System.get_env("GOOGLE_API_KEY")
if is_nil(key) or key == "" do
  IO.puts("Error: GOOGLE_API_KEY not set.")
  System.halt(1)
end

url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=#{key}"
body = %{
  systemInstruction: %{parts: [%{text: "You are a visual director. Respond with a single concise sentence describing a scene."}]},
  contents: [
    %{role: "user", parts: [%{text: "O pato pateta pintou o caneco"}]}
  ],
  generationConfig: %{
    temperature: 0.8,
    maxOutputTokens: 100,
    thinkingConfig: %{thinkingBudget: 0}
  }
}

start_time = System.system_time(:millisecond)
case Req.post(url, json: body, receive_timeout: 10_000, retry: false) do
  {:ok, %{status: 200, body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]}}} ->
    elapsed = System.system_time(:millisecond) - start_time
    IO.puts("Success in #{elapsed}ms!")
    IO.puts("Response: #{String.trim(text)}")

  {:ok, resp} ->
    elapsed = System.system_time(:millisecond) - start_time
    IO.puts("Failed (HTTP #{resp.status}) in #{elapsed}ms")
    IO.puts("Body: #{inspect(resp.body)}")

  {:error, reason} ->
    IO.puts("Network Error: #{inspect(reason)}")
end
