defmodule AtlasRuntime.Agent.Codex do
  @moduledoc """
  Official Codex CLI, using its existing ChatGPT login. Goals default to read-only;
  explicit `sandbox: workspace-write` permits edits under Codex's workspace policy.
  Requires explicit `command`, `workspace` and `goal` agent settings. The Python
  runner owns a process group and reaps it on stop or parent loss. JSONL output,
  stderr and the final answer stay under `turns_dir/<turn key>`. Guidance is not
  supported. Success requires both Codex's completed event and a clean process exit.
  """
  use GenServer
  @behaviour AtlasRuntime.Agent

  @impl AtlasRuntime.Agent
  def start(turn, opts), do: GenServer.start(__MODULE__, {self(), turn, opts})

  @impl AtlasRuntime.Agent
  def stop(pid) do
    GenServer.call(pid, :stop, 10_000)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  @impl true
  def init({owner, turn, opts}) do
    settings = Keyword.fetch!(opts, :agent)
    folder = Path.join(Keyword.fetch!(opts, :turns_dir), turn.key)
    command = settings["command"] && System.find_executable(settings["command"])
    python = System.find_executable("python3")
    workspace = settings["workspace"]
    goal = settings["goal"]
    sandbox = Map.get(settings, "sandbox", "read-only")

    if command && python && is_binary(workspace) && File.dir?(workspace) &&
         is_binary(goal) && String.trim(goal) != "" && sandbox in ["read-only", "workspace-write"] do
      File.mkdir_p!(folder)
      helper = Path.join(:code.priv_dir(:atlas_runtime), "codex_runner.py")
      kept = ~w(HOME USER LOGNAME PATH TMPDIR LANG LC_ALL LC_CTYPE CODEX_HOME)
      unset = for {key, _} <- System.get_env(), key not in kept, do: {String.to_charlist(key), false}
      port = Port.open({:spawn_executable, python}, [
        :binary, :exit_status, {:line, 65_536},
        {:args, [helper, command, Path.expand(workspace), Path.expand(folder), goal, sandbox]},
        {:env, unset}
      ])
      monitor = Process.monitor(owner)
      {:ok, %{owner: owner, monitor: monitor, port: port, partial: "", completed: false,
               failed: false, result: nil, process_exit: nil, stopping: nil}}
    else
      {:stop, :codex_requires_command_workspace_goal_and_python}
    end
  end

  @impl true
  def handle_call(:stop, from, state) do
    Port.command(state.port, "stop\n")
    {:noreply, %{state | stopping: from}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state) do
    Port.command(state.port, "stop\n")
    {:noreply, %{state | stopping: :owner_gone}}
  end

  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state) do
    if byte_size(state.partial) + byte_size(part) > 2_097_152,
      do: {:stop, :codex_event_too_large, state},
      else: {:noreply, %{state | partial: state.partial <> part}}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case JSON.decode(state.partial <> line) do
      {:ok, record} -> {:noreply, consume(record, %{state | partial: ""})}
      _ -> {:stop, :invalid_codex_runner_event, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    cond do
      state.stopping != nil and status == 0 and is_integer(state.process_exit) ->
        if state.stopping != :owner_gone, do: GenServer.reply(state.stopping, :ok)
        {:stop, :normal, %{state | port: nil}}
      status == 0 and state.process_exit == 0 and state.completed and not state.failed ->
        send(state.owner, {:agent, self(), {:ended, state.result || "Codex completed the goal"}})
        {:stop, :normal, %{state | port: nil}}
      true ->
        {:stop, {:codex_failed, status, state.process_exit}, %{state | port: nil}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp consume(%{"type" => "runtime.process_ended", "exit_code" => code}, state),
    do: %{state | process_exit: code}

  defp consume(%{"type" => "runtime.event", "event" => event}, state) do
    type = event["type"] || "output"
    item = event["item"] || %{}
    text = item["text"]
    activity = if is_binary(text), do: String.slice(text, 0, 240), else: type
    send(state.owner, {:agent, self(), {:activity, "codex: " <> activity}})
    state = if type == "turn.completed", do: %{state | completed: true}, else: state
    state = if type in ["turn.failed", "error"], do: %{state | failed: true}, else: state
    if type == "item.completed" and item["type"] == "agent_message" and is_binary(text),
      do: %{state | result: String.slice(text, 0, 2_000)}, else: state
  end

  defp consume(_, state), do: state

  @impl true
  def terminate(_, %{port: port}) when is_port(port) do
    # Closing stdin tells the helper to stop and reap its owned process group.
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
  def terminate(_, _), do: :ok
end
