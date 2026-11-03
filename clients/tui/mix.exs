defmodule AtlasTui.MixProject do
  use Mix.Project

  # A client of Control, not part of the BEAM platform: it shares no code with it and
  # knows only Control's blocks (generated from Control's spec into lib/atlas_tui/blocks.ex).
  def project do
    [
      app: :atlas_tui,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
