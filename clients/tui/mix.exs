defmodule AtlasTui.MixProject do
  use Mix.Project

  # A client of Control, not part of the BEAM platform: it shares no code with it and
  # knows only Control's blocks (generated from Control's spec into lib/atlas_tui/blocks.ex)
  # and the rules of markup, which are part of that spec (spec/control/rules).
  def project do
    [
      app: :atlas_tui,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: ["lib", Path.expand("../../spec/control/rules", __DIR__)],
      start_permanent: false,
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
