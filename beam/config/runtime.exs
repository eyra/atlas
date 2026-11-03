import Config

# The Atlas environment (test or prod) is not Mix's environment. `bin/atlas up --env <env>`
# sets ATLAS_ENV; its settings come from env/<env>.json at the repository root, the one
# file the BEAM node and the clients both read. There is no default: a node only starts
# for the environment it was told, so nothing reaches prod by accident.
if config_env() != :test do
  env = System.get_env("ATLAS_ENV")

  if env not in ["test", "prod"] do
    raise "ATLAS_ENV is #{inspect(env)}; start the core with bin/atlas up --env test|prod"
  end

  root = System.get_env("ATLAS_ROOT") || Path.expand("../..", __DIR__)
  # ATLAS_ENV_FILE runs a second, private instance of an environment (other ports, other
  # data), so an agent's test run never meets the one Melle is using.
  file = System.get_env("ATLAS_ENV_FILE") || Path.join(root, "env/#{env}.json")
  settings = file |> File.read!() |> JSON.decode!()

  if settings["env"] != env do
    raise "#{file} is for #{inspect(settings["env"])}, not #{env}"
  end

  expand = &Path.expand(String.replace_prefix(&1, "~", System.user_home!()))

  config :atlas_bus, environment: env

  config :atlas_state,
    rela_url: settings["rela"]["url"],
    # On Fly rela has an IPv6 address on the private network only.
    rela_ipv6: settings["rela"]["ipv6"] == true,
    description_extra: settings["rela"]["extra"] && Path.join(root, settings["rela"]["extra"]),
    data_dir: expand.(settings["state"]["data"]),
    # The connectors at State's edge: only those this environment has settings for.
    connectors: settings["connectors"] || %{}

  config :atlas_control,
    host: settings["control"]["host"],
    port: settings["control"]["port"],
    # Who uses a TUI of this environment (a key), until Control has sign-in.
    tui_user: settings["tui_user"]

  # Flow looks at each open fact again this often, and at once on a hint.
  config :atlas_flow, tick_seconds: get_in(settings, ["flow", "tick_seconds"]) || 60
end
