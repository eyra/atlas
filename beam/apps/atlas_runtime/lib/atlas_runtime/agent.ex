defmodule AtlasRuntime.Agent do
  @moduledoc """
  The port to the agent behind a turn (architecture v4, section 13: the agents are outside
  BEAM, and Runtime starts, watches and ends them). A port starts the agent for one turn
  and returns the process that stands for it. That process tells the turn, its caller:

  - `{:agent, pid, {:activity, what}}`: the agent did something (output, a tool, a fact);
  - `{:agent, pid, {:ended, why}}`: the agent ended its turn itself.

  An agent that crashes is a process that exits abnormally; the turn monitors it. `stop/1`
  ends the agent's turn from Runtime's side (silent, too long, no longer the owner).

  The ports: `stub` (`AtlasRuntime.Agent.Stub`, for tests and the end-to-end test) and
  `claude` (`AtlasRuntime.Agent.Claude`, Claude Code headless, IS-Atlas-18).
  """

  @doc "Start the agent for `turn` (`%{key, item, agent}`); messages go to the caller."
  @callback start(turn :: map, opts :: keyword) :: {:ok, pid} | {:error, term}

  @doc "End the agent's turn."
  @callback stop(pid) :: :ok

  @ports %{"stub" => AtlasRuntime.Agent.Stub, "claude" => AtlasRuntime.Agent.Claude}

  @doc "The port a machine's settings name for an agent, or nil."
  def port(%{"port" => name}), do: @ports[name]
  def port(_), do: nil
end
