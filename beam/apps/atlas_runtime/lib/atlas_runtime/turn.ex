defmodule AtlasRuntime.Turn do
  @moduledoc """
  One running turn (architecture v4, section 3): an agent acting on one item. It starts the
  agent through its port, and puts every step as a fact in State, with its cause:

  - the turn, `running`, on its item and by its agent, with a lease until the silence limit
    (W1, W2);
  - its lease, renewed while the agent shows activity: until its last activity plus the
    silence limit, at most every `lease` (W2);
  - its end, `ended`, with why: the agent ended it, it was silent for the silence limit
    (W2), it ran longer than the maximum (W4), the agent crashed, or the item is no longer
    the agent's (the engine says so).

  It keeps nothing State does not hold, but the agent itself: when its process dies, the
  engine finds the turn running without a process and ends it (C1). Whether the turn moved
  its item (W3) is the item's process's question, in Flow, not Runtime's.

  The turn's kind and fields are the description's (`runtime.turn` in `rela/atlas.json`):
  this module names none.
  """
  use GenServer, restart: :temporary

  require Logger

  alias AtlasRuntime.Talk

  def start_link(turn), do: GenServer.start_link(__MODULE__, turn, name: via(turn.key))

  def via(key), do: {:via, Registry, {AtlasRuntime.Turns, key}}

  @doc "End the turn, with why (from the engine)."
  def finish(pid, why), do: GenServer.cast(pid, {:finish, why})

  @impl true
  def init(turn) do
    :ok = AtlasBus.attach("runtime/#{turn.key}")
    # The turn's agent and item, for the registry: one turn per agent at a time.
    Registry.update_value(AtlasRuntime.Turns, turn.key, fn _ -> {turn.agent, turn.item} end)
    # Starting waits for State; the engine that started it does not.
    {:ok, turn, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, turn) do
    case turn.port.start(%{key: turn.key, item: turn.item, agent: turn.agent}, turn.port_opts) do
      {:ok, agent} ->
        ref = Process.monitor(agent)
        now = now()

        state =
          Map.merge(turn, %{
            agent_pid: agent,
            ref: ref,
            since: now,
            active: now,
            written: now,
            what: nil
          })

        n = turn.names

        values = %{
          n.state => n.running,
          n.machine => turn.machine,
          n.lease => at(now + turn.silence),
          n.activity => "started"
        }

        case put(state, "create", values, turn.cause) do
          :ok ->
            schedule(state)
            {:noreply, state}

          {:error, why} ->
            turn.port.stop(agent)
            Logger.warning("runtime: #{turn.key} not started: #{why}")
            {:stop, :normal, state}
        end

      {:error, why} ->
        Logger.warning(
          "runtime: #{turn.key} not started: the agent did not start: #{inspect(why)}"
        )

        {:stop, :normal, turn}
    end
  end

  @impl true
  def handle_info({:agent, pid, {:activity, what}}, %{agent_pid: pid} = state),
    do: {:noreply, %{state | active: now(), what: what}}

  def handle_info({:agent, pid, {:ended, why}}, %{agent_pid: pid} = state) do
    Process.demonitor(state.ref, [:flush])
    finish_turn(%{state | agent_pid: nil}, "the agent ended its turn: #{why}")
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = state) do
    why =
      case reason do
        :normal -> "the agent stopped"
        reason -> "the agent crashed: #{inspect(reason)}"
      end

    finish_turn(%{state | agent_pid: nil}, why)
  end

  def handle_info(:tick, state) do
    now = now()

    cond do
      now - state.active >= state.silence ->
        finish_turn(
          state,
          "silent for #{div(state.silence, 1000)} s: no activity since #{at(state.active)}"
        )

      now - state.since >= state.max ->
        finish_turn(state, "longer than the maximum of #{div(state.max, 1000)} s")

      state.active > state.written ->
        n = state.names

        values = %{
          n.lease => at(state.active + state.silence),
          n.activity => state.what || "activity"
        }

        case put(state, "change", values, "activity: #{state.what || "activity"}") do
          :ok ->
            schedule(state)
            {:noreply, %{state | written: state.active}}

          {:error, _why} ->
            # State did not store it: the lease runs out by itself if this goes on.
            schedule(state)
            {:noreply, state}
        end

      true ->
        schedule(state)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:finish, why}, state), do: finish_turn(state, why)

  defp finish_turn(state, why) do
    if state.agent_pid, do: state.port.stop(state.agent_pid)
    n = state.names

    case put(state, "change", %{n.state => n.ended, n.why => why, n.lease => ""}, why) do
      :ok ->
        Logger.info("runtime: #{state.key} ended: #{why}")

      {:error, failed} ->
        Logger.warning("runtime: #{state.key} not ended in State (#{failed}); the engine ends it")
    end

    {:stop, :normal, state}
  end

  # Every write is a fact with its cause, by Runtime.
  defp put(state, op, values, cause) do
    n = state.names

    content = %{
      "op" => op,
      "key" => state.key,
      "values" => values,
      "version" => nil,
      "by" => "runtime",
      "cause" => cause
    }

    content =
      if op == "create",
        do: Map.put(content, "links", %{n.on => [state.item], n.by => [state.agent]}),
        else: content

    case Talk.put(state.turn_kind, content) do
      {:stored, _} -> :ok
      {:refused, reasons} -> {:error, Enum.join(List.wrap(reasons), "; ")}
      {:error, why} -> {:error, inspect(why)}
    end
  end

  defp schedule(state), do: Process.send_after(self(), :tick, min(state.lease, state.silence))

  defp now, do: System.system_time(:millisecond)

  defp at(ms),
    do:
      ms
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
end
