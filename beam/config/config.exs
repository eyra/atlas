import Config

# The Bus hands facts and reads to this endpoint; it never knows what they mean.
config :atlas_bus, store: "state", environment: "test"

import_config "#{config_env()}.exs"
