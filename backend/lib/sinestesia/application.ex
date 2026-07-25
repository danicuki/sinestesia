defmodule Sinestesia.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    config = Application.fetch_env!(:sinestesia, :config)
    port = Keyword.fetch!(config, :port)

    # The test suite doesn't need the listener, and binding the port would make
    # `mix test` fail whenever a backend is already running — which, during a
    # rehearsal, is always.
    serve? = Application.get_env(:sinestesia, :start_server, true)

    children =
      [
        {Registry, keys: :unique, name: Sinestesia.PipelineRegistry},
        Sinestesia.Verifiability
      ] ++ if serve?, do: [{Bandit, plug: Sinestesia.Router, port: port}], else: []

    if serve? do
      # Print everything, not one arbitrary setting. The old line named
      # OLLAMA_MODEL unconditionally, so a show running the Director on 0G
      # still announced "Director: gemma4:12b-mlx" — the local model that
      # wasn't involved. See Sinestesia.Config.
      Logger.info("Sinestesia booting on :#{port}")
      Sinestesia.Config.log_boot()
    end

    opts = [strategy: :one_for_one, name: Sinestesia.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
