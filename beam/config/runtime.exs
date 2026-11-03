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
  settings = root |> Path.join("env/#{env}.json") |> File.read!() |> JSON.decode!()
  expand = &Path.expand(String.replace_prefix(&1, "~", System.user_home!()))

  config :atlas_bus, environment: env

  config :atlas_state,
    rela_url: settings["rela"]["url"],
    data_dir: expand.(settings["state"]["data"])

  config :atlas_control,
    host: settings["control"]["host"],
    port: settings["control"]["port"]
end
