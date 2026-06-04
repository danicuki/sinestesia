import Config

config :logger, :default_formatter,
  format: "$time [$level] $message $metadata\n",
  metadata: [:module]

import_config "#{config_env()}.exs"
