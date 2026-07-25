import Config

# The suite exercises pure functions (config registry, doc generation); binding
# the real port would just collide with whatever backend is already running.
config :sinestesia, start_server: false
config :logger, level: :warning
