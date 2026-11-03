import Config

# The Atlas environment (test or prod) is not Mix's environment. `bin/atlas up --env test`
# sets ATLAS_ENV; its settings come from env/<env>.json at the repository root, the one
# file the BEAM node and the clients both read.
if config_env() != :test do
  env = System.get_env("ATLAS_ENV", "prod")

  if env != "test" do
    raise "Atlas #{env} is not built yet; start with --env test"
  end

  root = System.get_env("ATLAS_ROOT") || Path.expand("../..", __DIR__)
  # ATLAS_ENV_FILE runs a second, private instance of an environment (other ports, other
  # data), so an agent's test run never meets the one Melle is using.
  file = System.get_env("ATLAS_ENV_FILE") || Path.join(root, "env/#{env}.json")
  settings = file |> File.read!() |> JSON.decode!()
  expand = &Path.expand(String.replace_prefix(&1, "~", System.user_home!()))

  config :atlas_bus, environment: env

  config :atlas_state,
    rela_url: settings["rela"]["url"],
    description_extra: settings["rela"]["extra"] && Path.join(root, settings["rela"]["extra"]),
    data_dir: expand.(settings["state"]["data"])

  config :atlas_control,
    host: settings["control"]["host"],
    port: settings["control"]["port"]
end
