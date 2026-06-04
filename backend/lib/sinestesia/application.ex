defmodule Sinestesia.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    config = Application.fetch_env!(:sinestesia, :config)
    port = Keyword.fetch!(config, :port)

    children = [
      {Registry, keys: :unique, name: Sinestesia.PipelineRegistry},
      {Bandit, plug: Sinestesia.Router, port: port}
    ]

    Logger.info("Sinestesia booting on :#{port} (Director: #{Keyword.get(config, :ollama_model)})")

    opts = [strategy: :one_for_one, name: Sinestesia.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
