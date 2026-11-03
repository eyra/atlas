defmodule AtlasControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_control,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {AtlasControl.Application, []}]
  end

  # The block catalogue lives with the rest of Control's spec, in spec/control.
  @spec_dir Path.expand("../../../spec/control", __DIR__)

  defp elixirc_paths(:test), do: ["lib", @spec_dir, "test/support"]
  defp elixirc_paths(_), do: ["lib", @spec_dir]

  # Control reaches the other layers only over the Bus.
  defp deps, do: [{:atlas_bus, in_umbrella: true}]
end
