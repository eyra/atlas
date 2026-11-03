defmodule AtlasContract.MixProject do
  use Mix.Project

  # Control's contract: the blocks, models and kinds of markup Control sends and every
  # client renders. Only the catalogue lives here; the DSL, the rules and the targets
  # are the generator's (spec/generator).
  def project do
    [
      app: :atlas_contract,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:atlas_spec, path: "../generator"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
