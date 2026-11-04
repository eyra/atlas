defmodule AtlasRuntime.Settings do
  @moduledoc """
  What this machine's Runtime runs, from the environment's settings (`runtime` in
  `env/<env>.json`): `machine` (its name), `agents` (`%{key => %{"port" => port}}`: the
  agents it runs, each through a port, `AtlasRuntime.Agent`), and its numbers (architecture
  v4, section 10.4): `silence_seconds` (a turn without activity this long ends, 600),
  `max_seconds` (the longest a turn runs, 7200), `lease_seconds` (how often a turn's lease
  is renewed while there is activity, 60) and `round_seconds` (how often it reconciles the
  turns with State, 60, and at once on a hint). No `runtime`: no agents, nothing runs.
  """

  @doc "The engine's options."
  def get do
    settings = Application.get_env(:atlas_runtime, :settings) || %{}

    [
      machine: settings["machine"] || "this machine",
      agents: settings["agents"] || %{},
      silence: seconds(settings["silence_seconds"], 600),
      max: seconds(settings["max_seconds"], 7200),
      lease: seconds(settings["lease_seconds"], 60),
      every: seconds(settings["round_seconds"], 60),
      stub_dir: settings["stub_dir"]
    ]
  end

  defp seconds(nil, default), do: default * 1000
  defp seconds(n, _default) when is_number(n), do: round(n * 1000)
end
