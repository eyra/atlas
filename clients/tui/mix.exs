defmodule AtlasTui.MixProject do
  use Mix.Project

  # A client of Control, not part of the BEAM platform: it shares no code with it and
  # knows only Control's contract (spec/contract), read at compile time into
  # lib/atlas_tui/blocks.ex, with the generator that reads it (spec/generator).
  def project do
    [
      app: :atlas_tui,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:atlas_contract, path: "../../spec/contract"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
