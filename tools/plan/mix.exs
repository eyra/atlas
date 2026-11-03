defmodule AtlasPlan.MixProject do
  use Mix.Project

  # UC-Atlas-05: loads the plan from SCENES.md into Atlas, through Control, with the agent
  # client (clients/agent), as an agent would. Not part of the BEAM platform or of any
  # client: it knows SCENES.md's layout, and so the kinds of the plan by name.
  def project do
    [
      app: :atlas_plan,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:atlas_agent, path: "../../clients/agent"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
