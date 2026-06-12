# Run this script with: mix run scripts/test_cloudflare.exs
# It verifies Cloudflare Workers AI connectivity and latency.

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

account = System.get_env("CLOUDFLARE_ACCOUNT_ID")
token = System.get_env("CLOUDFLARE_API_TOKEN")

if is_nil(account) or account == "" or is_nil(token) or token == "" do
  IO.puts("Error: Cloudflare credentials not set in environment or .env file.")
  System.halt(1)
end

models = [
  {"flux-1-schnell", "@cf/black-forest-labs/flux-1-schnell", %{prompt: "A beautiful watercolor painting of a solitary boat on a calm, misty lake, high quality, artistic", steps: 4}},
  {"sdxl-base", "@cf/stabilityai/stable-diffusion-xl-base-1.0", %{prompt: "A beautiful watercolor painting of a solitary boat on a calm, misty lake, high quality, artistic", num_steps: 20}},
  {"dreamshaper-8-lcm", "@cf/lykon/dreamshaper-8-lcm", %{prompt: "A beautiful watercolor painting of a solitary boat on a calm, misty lake, high quality, artistic", num_steps: 4}}
]

Enum.each(models, fn {name, model, body} ->
  IO.puts("\n=== Testing Cloudflare Model: #{name} (#{model}) ===")
  url = "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/run/#{model}"

  start_time = System.system_time(:millisecond)
  case Req.post(url,
         json: body,
         auth: {:bearer, token},
         receive_timeout: 30_000,
         retry: false
       ) do
    {:ok, %{status: 200, body: resp}} ->
      elapsed = System.system_time(:millisecond) - start_time
      IO.puts("Success in #{elapsed}ms!")
      
      # For different models, the response type might differ (JSON with base64 vs raw binary)
      case resp do
        %{"result" => %{"image" => b64}} ->
          IO.puts("Received JSON with base64 image (length: #{byte_size(b64)})")
          File.write!("test_cf_output_#{name}.jpg", Base.decode64!(b64))
        bin when is_binary(bin) ->
          IO.puts("Received raw binary image (length: #{byte_size(bin)})")
          File.write!("test_cf_output_#{name}.jpg", bin)
        other ->
          IO.puts("Received unexpected response format: #{inspect(other, limit: 5)}")
      end
      IO.puts("Saved sample to test_cf_output_#{name}.jpg")

    {:ok, resp} ->
      elapsed = System.system_time(:millisecond) - start_time
      IO.puts("Failed (HTTP #{resp.status}) in #{elapsed}ms")
      IO.puts("Body: #{inspect(resp.body, limit: 10)}")

    {:error, reason} ->
      IO.puts("Network Error: #{inspect(reason)}")
  end
end)
