# Runtime service. Neither Atlas core services nor an orchestration engine starts.
Application.put_env(:atlas_runtime, :start, false)
{:ok, _} = Application.ensure_all_started(:atlas_runtime)
started = Enum.map(Application.started_applications(), &elem(&1, 0))

if Enum.any?([:atlas_state, :atlas_flow, :atlas_control], &(&1 in started)),
  do: raise("Runtime must not start Atlas core services")

defmodule AtlasRuntime.Service do
  use GenServer
  alias AtlasRuntime.Agent.Codex

  def start(dir), do: GenServer.start_link(__MODULE__, dir, name: __MODULE__)

  def init(dir) do
    path = Path.join(dir, "runtime.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, path},
        packet: :line,
        packet_size: 1_048_576,
        buffer: 1_048_576,
        active: false
      ])

    File.chmod!(path, 0o600)
    System.at_exit(fn _ -> File.rm(path) end)
    spawn_link(fn -> accept(listener) end)
    {:ok, %{dir: dir, agent: nil, monitor: nil, stopping: false, run: %{state: "idle"}}}
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)

    pid =
      spawn(fn ->
        receive do
          {:socket, s} -> connection(s)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, {:socket, socket})
    accept(listener)
  end

  defp connection(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} ->
        {reply, shutdown?} =
          case JSON.decode(bytes) do
            {:ok, request} when is_map(request) -> GenServer.call(__MODULE__, request, 30_000)
            _ -> {%{command_error: "Expected a JSON command"}, false}
          end

        :gen_tcp.send(socket, JSON.encode!(reply) <> "\n")
        :gen_tcp.close(socket)
        if shutdown?, do: send(__MODULE__, :shutdown)

      _ ->
        :gen_tcp.close(socket)
    end
  end

  def handle_call(request, _from, state) do
    try do
      {reply, next, shutdown?} = command(request, state)
      {:reply, {reply, shutdown?}, next}
    rescue
      error -> {:reply, {%{command_error: Exception.message(error)}, false}, state}
    catch
      :exit, why ->
        {:reply, {%{command_error: "Operation not confirmed: #{inspect(why)}"}, false}, state}
    end
  end

  defp command(_, %{stopping: true}), do: raise("Runtime service is stopping")

  defp command(%{"command" => "service-status"}, state),
    do: {%{service: "running", pid: System.pid(), agent_state: state.run.state}, state, false}

  defp command(%{"command" => "service-stop"}, state) do
    next = stop(state)
    {%{service: "stopping", agent: next.run}, %{next | stopping: true}, true}
  end

  defp command(%{"command" => "status"}, state), do: {state.run, state, false}

  defp command(%{"command" => "stop"}, state) do
    next = stop(state)
    {next.run, next, false}
  end

  defp command(%{"command" => "output"}, state) do
    output =
      if state.run[:artifacts] do
        folder = state.run.artifacts

        answer =
          case File.read(Path.join(folder, "answer.txt")) do
            {:ok, text} -> text
            _ -> nil
          end

        %{answer: answer, recent_events: recent(Path.join(folder, "stream.jsonl"))}
      else
        %{answer: nil, recent_events: ""}
      end

    {Map.merge(state.run, output), state, false}
  end

  defp command(%{"command" => "start", "cwd" => cwd, "assignment" => assignment} = request, state)
       when is_binary(cwd) and is_binary(assignment) do
    if state.agent, do: raise("An agent is already active; use status or stop")
    sandbox = Map.get(request, "sandbox", "read-only")

    if sandbox not in ["read-only", "workspace-write"],
      do: raise("Sandbox must be read-only or workspace-write")

    if not File.dir?(cwd) or String.trim(assignment) == "",
      do: raise("An existing working directory and nonempty assignment are required")

    executable = System.find_executable("codex") || raise("Install Codex and run codex login")
    key = "turn-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    turns = Path.join(state.dir, "turns")

    settings = %{
      "command" => executable,
      "workspace" => Path.expand(cwd),
      "goal" => assignment,
      "sandbox" => sandbox
    }

    case Codex.start(%{key: key}, agent: settings, turns_dir: turns) do
      {:ok, pid} ->
        run = %{
          id: key,
          state: "running",
          cwd: Path.expand(cwd),
          assignment: assignment,
          sandbox: sandbox,
          artifacts: Path.join(turns, key)
        }

        next = %{state | agent: pid, monitor: Process.monitor(pid), run: run}
        {run, next, false}

      {:error, why} ->
        raise("Codex start failed: #{inspect(why)}")
    end
  end

  defp command(_, _), do: raise("Unknown or malformed command")

  defp stop(%{agent: nil} = state), do: state

  defp stop(state) do
    :ok = Codex.stop(state.agent)
    Process.demonitor(state.monitor, [:flush])
    %{state | agent: nil, monitor: nil, run: Map.put(state.run, :state, "stopped")}
  end

  def handle_info({:agent, pid, {:activity, text}}, %{agent: pid} = state),
    do: {:noreply, %{state | run: Map.put(state.run, :activity, text)}}

  def handle_info({:agent, pid, {:ended, text}}, %{agent: pid} = state) do
    Process.demonitor(state.monitor, [:flush])

    {:noreply,
     %{
       state
       | agent: nil,
         monitor: nil,
         run: Map.merge(state.run, %{state: "finished", result: text})
     }}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{monitor: ref} = state) do
    {:noreply,
     %{
       state
       | agent: nil,
         monitor: nil,
         run: Map.merge(state.run, %{state: "failed", error: inspect(reason)})
     }}
  end

  def handle_info(:shutdown, state) do
    System.stop(0)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Bounded diagnostic tail; full native output remains in the artifact file.
  defp recent(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {:ok, size} = :file.position(file, :eof)
          offset = max(0, size - 65_536)
          {:ok, _} = :file.position(file, offset)

          case :file.read(file, 65_536) do
            {:ok, bytes} ->
              lines = String.split(bytes, "\n")
              lines = if offset > 0, do: tl(lines), else: lines
              Enum.join(lines, "\n")

            _ ->
              ""
          end
        after
          File.close(file)
        end

      _ ->
        ""
    end
  end
end

[dir] = System.argv()
{:ok, _} = AtlasRuntime.Service.start(dir)
IO.puts("Runtime ready; Atlas core services remain stopped")
Process.sleep(:infinity)
