defmodule AtlasBFFContract.MixProject do
  use Mix.Project

  # Control's contract: the blocks, models and kinds of markup Control sends and every
  # client renders. Only the catalogue lives here; the DSL, the rules and the targets
  # are the generator's (bff/generator).
  def project do
    [
      app: :atlas_bff_contract,
      version: "0.14.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:atlas_bff, path: "../generator"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
