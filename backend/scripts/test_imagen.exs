# Run this script with: mix run scripts/test_imagen.exs
# It verifies Google Imagen 3 API connectivity and latency.

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
  IO.puts("Error: GOOGLE_API_KEY is not set in environment or .env file.")
  System.halt(1)
end

# We will test both imagen-3.0-generate-002 and imagen-4.0-fast-generate-001 (if it exists)
models = ["imagen-3.0-generate-002", "imagen-4.0-fast-generate-001"]

Enum.each(models, fn model ->
  IO.puts("\n=== Testing model: #{model} ===")
  url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:predict?key=#{key}"
  body = %{
    instances: [%{prompt: "A beautiful watercolor painting of a solitary boat on a calm, misty lake, high quality, artistic"}],
    parameters: %{
      sampleCount: 1,
      aspectRatio: "16:9"
    }
  }

  start_time = System.system_time(:millisecond)
  case Req.post(url, json: body, receive_timeout: 15_000, retry: false) do
    {:ok, %{status: 200, body: %{"predictions" => [%{"bytesBase64Encoded" => b64} | _]}}} ->
      elapsed = System.system_time(:millisecond) - start_time
      IO.puts("Success! Latency: #{elapsed}ms")
      IO.puts("Base64 string length: #{byte_size(b64)}")
      # Save a sample to verify
      File.write!("test_imagen_output_#{model}.jpg", Base.decode64!(b64))
      IO.puts("Saved sample to test_imagen_output_#{model}.jpg")

    {:ok, resp} ->
      elapsed = System.system_time(:millisecond) - start_time
      IO.puts("Failed (HTTP #{resp.status}) in #{elapsed}ms")
      IO.puts("Body: #{inspect(resp.body)}")

    {:error, reason} ->
      IO.puts("Network Error: #{inspect(reason)}")
  end
end)
