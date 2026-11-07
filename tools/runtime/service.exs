# Runtime service. Neither Atlas core services nor an orchestration engine starts.
Application.put_env(:atlas_runtime, :start, false)
{:ok, _} = Application.ensure_all_started(:atlas_runtime)
started = Enum.map(Application.started_applications(), &elem(&1, 0))

if Enum.any?([:atlas_state, :atlas_flow, :atlas_control], &(&1 in started)),
  do: raise("Runtime must not start Atlas core services")

defmodule AtlasRuntime.Service do
  use GenServer
  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.BackendPolicy
  alias AtlasRuntime.ExecutionEvents

  def start(dir), do: GenServer.start_link(__MODULE__, dir, name: __MODULE__)

  def init(dir) do
    policy = case File.read(Path.join(dir, "backends.json")) do
      {:ok, bytes} -> BackendPolicy.validate!(JSON.decode!(bytes))
      {:error, :enoent} -> BackendPolicy.empty()
      {:error, reason} -> raise("Cannot read backend policy: #{inspect(reason)}")
    end
    events = ExecutionEvents.open(dir)
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
    {:ok, %{dir: dir, policy: policy, events: events, agent: nil, monitor: nil, stopping: false, run: %{state: "idle"}}}
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
    {reply, next, shutdown?} =
      try do
        command(request, state)
      rescue
        error -> {%{command_error: Exception.message(error)}, state, false}
      catch
        :exit, why -> {%{command_error: "Operation not confirmed: #{inspect(why)}"}, state, false}
      end

    next =
      if next.run != state.run do
        persist(next.run)
        %{next | events: ExecutionEvents.append(next.dir, next.events, next.run)}
      else
        next
      end
    {:reply, {reply, shutdown?}, next}
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

  defp command(%{"command" => "events"} = request, state) do
    if Map.keys(request) -- ["command", "cursor", "limit"] != [],
      do: raise("Events accepts only an optional cursor and limit")
    reply = ExecutionEvents.query(state.events, Map.get(request, "cursor"), Map.get(request, "limit", 50))
    {reply, state, false}
  end

  defp command(%{"command" => "turns"}, state) do
    root = Path.join(state.dir, "turns")
    entries = case File.ls(root) do
      {:ok, entries} -> entries
      {:error, :enoent} -> []
      {:error, reason} -> raise("Cannot read turn history: #{inspect(reason)}")
    end
    turns =
      entries
      |> Enum.filter(&valid_id?/1)
      |> Enum.filter(&File.dir?(Path.join(root, &1)))
      |> Enum.map(&historical(&1, state))
      |> Enum.sort_by(&{&1["started_at"] || "", &1["id"]}, :desc)
    {%{turns: turns}, state, false}
  end

  defp command(%{"command" => "output", "turn_id" => id}, state) do
    run = historical(id, state)
    {Map.merge(run, turn_output(run["artifacts"])), state, false}
  end

  defp command(%{"command" => "output"}, state) do
    {Map.merge(state.run, turn_output(state.run[:artifacts])), state, false}
  end

  defp command(%{"command" => "preferences"} = request, state) do
    now = System.system_time(:second)
    policy = case request do
      %{"preferred" => preferred, "fallback" => fallback} when map_size(request) == 3 ->
        BackendPolicy.configure(state.policy, preferred, fallback)
      %{"reenable" => backend} when map_size(request) == 2 ->
        BackendPolicy.reenable(state.policy, backend, now)
      _ when map_size(request) == 1 -> state.policy
      _ -> raise("Use preferences, a preferred/fallback pair, or reenable; modes cannot mix")
    end
    if policy != state.policy, do: persist_policy(state.dir, policy)
    {BackendPolicy.view(policy, now), %{state | policy: policy}, false}
  end

  defp command(%{"command" => "start", "repository" => url, "branch" => branch,
                 "permissions" => "dedicated-repository", "assignment" => assignment} = request, state)
       when is_binary(url) and is_binary(branch) and is_binary(assignment) do
    if state.agent, do: raise("An agent is already active; use status or stop")
    selection = select_backend(request, state)
    if Map.keys(request) -- ["command", "repository", "branch", "permissions", "assignment", "backend"] != [],
      do: raise("Repository provisioning cannot be combined with cwd or sandbox")
    prepared = Native.repository_request(state.dir, url, branch)
    scope = prepared["permissions"]
    start_turn(assignment, scope["root"], nil, scope, nil, state, prepared["repository"], selection)
  end

  defp command(%{"command" => "start", "cwd" => cwd, "assignment" => assignment} = request, state)
       when is_binary(cwd) and is_binary(assignment) do
    if state.agent, do: raise("An agent is already active; use status or stop")
    if Map.has_key?(request, "repository") or Map.has_key?(request, "branch"),
      do: raise("Repository provisioning requires a URL, branch and dedicated-repository permissions")
    selection = select_backend(request, state)
    {sandbox, scope} =
      case Map.get(request, "permissions") do
        nil ->
          sandbox = Map.get(request, "sandbox", "read-only")
          if sandbox not in ["read-only", "workspace-write"],
            do: raise("Sandbox must be read-only or workspace-write")
          {sandbox, nil}
        "dedicated-repository" ->
          if Map.has_key?(request, "sandbox"), do: raise("Permissions cannot be combined with sandbox")
          {nil, Native.permission_scope(cwd)}
        _ -> raise("Unknown permission profile")
      end
    start_turn(assignment, cwd, sandbox, scope, nil, state, nil, selection)
  end

  defp command(%{"command" => "continue", "assignment" => assignment} = request, state)
       when is_binary(assignment) do
    if Map.keys(request) -- ["command", "assignment", "turn_id"] != [],
      do: raise("Continue accepts only an assignment and optional turn ID; working directory and permissions cannot change")
    if state.agent, do: raise("An agent is already active; wait for completion or stop it")
    run =
      if Map.has_key?(request, "turn_id"),
        do: historical(request["turn_id"], state),
        else: Map.new(state.run, fn {key, value} -> {Atom.to_string(key), value} end)
    backend = Map.get(run, "backend", "codex")
    if backend not in ["codex", "claude"], do: raise("Unknown saved backend; sessions cannot switch vendors")
    if run["state"] != "finished",
      do: raise("Continue requires a successfully finished turn")
    session = run["session_id"]
    cwd = run["cwd"]
    sandbox = run["sandbox"]
    scope = run["permissions"]
    if not is_binary(session) or String.trim(session) == "",
      do: raise("The selected turn has no confirmed native session")
    if not is_binary(cwd) or Path.type(cwd) != :absolute or
         not ((is_nil(scope) and sandbox in ["read-only", "workspace-write"]) or
           (is_map(scope) and is_nil(sandbox))),
      do: raise("The selected turn has no valid saved working directory and permissions")
    if scope && scope != Native.permission_scope(cwd),
      do: raise("The selected turn's permission scope changed")
    context =
      if backend == "claude" do
        if not is_binary(run["model"]) or run["model"] == "",
          do: raise("The selected Claude turn has no confirmed model")
        Path.join(run["artifacts"], "claude-context.json") |> File.read!() |> JSON.decode!()
      end
    target = %{"backend" => backend, "model" => run["model"] || run["requested_model"]}
    selection = %{"requested" => target, "selected" => target, "reason" => "continuation"}
    start_turn(assignment, cwd, sandbox, scope, session, state, run["repository"], selection, context)
  end

  defp command(_, _), do: raise("Unknown or malformed command")

  defp select_backend(request, state) do
    if Map.has_key?(request, "backend") and is_nil(request["backend"]),
      do: raise("Backend must be codex or claude")
    BackendPolicy.select(state.policy, request["backend"], request, System.system_time(:second))
  end

  defp start_turn(assignment, cwd, sandbox, scope, session, state, repository, selection, context \\ nil) do
    backend = selection["selected"]["backend"]
    model = selection["selected"]["model"]
    if (not File.dir?(cwd) and is_nil(repository)) or String.trim(assignment) == "",
      do: raise("An existing working directory and nonempty assignment are required")

    executable = System.find_executable(backend) || raise("Install #{backend} and authenticate with its official CLI")
    key = "turn-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    turns = Path.join(state.dir, "turns")

    settings = %{
      "command" => executable,
      "backend" => backend,
      "model" => model,
      "workspace" => Path.expand(cwd),
      "goal" => assignment,
      "sandbox" => sandbox,
      "permissions" => scope,
      "repository" => repository,
      "session_id" => session,
      "resume_context" => context
    }

    case Native.start(%{key: key}, agent: settings, turns_dir: turns) do
      {:ok, pid} ->
        run = %{
          id: key,
          backend: backend,
          model: nil,
          requested_model: model,
          selection: selection,
          started_at: DateTime.to_iso8601(DateTime.utc_now()),
          state: "running",
          cwd: Path.expand(cwd),
          assignment: assignment,
          sandbox: sandbox,
          session_id: session,
          artifacts: Path.join(turns, key)
        }
        run = if scope, do: Map.put(run, :permissions, scope), else: run
        run = if repository, do: Map.put(run, :repository, repository), else: run

        next = %{state | agent: pid, monitor: Process.monitor(pid), run: run}
        {run, next, false}

      {:error, why} ->
        raise("#{backend} start failed: #{inspect(why)}")
    end
  end


  defp stop(%{agent: nil} = state), do: state

  defp stop(state) do
    :ok = Native.stop(state.agent)
    Process.demonitor(state.monitor, [:flush])
    %{state | agent: nil, monitor: nil,
      run: Map.merge(state.run, %{state: "stopped", ended_at: DateTime.to_iso8601(DateTime.utc_now())})}
  end

  def handle_info({:agent, pid, {:repository, repository}}, %{agent: pid} = state) do
    run = Map.put(state.run, :repository, repository)
    persist(run)
    {:noreply, %{state | run: run}}
  end

  def handle_info({:agent, pid, {:quota, evidence}},
                  %{agent: pid, run: %{backend: "claude"}} = state) do
    policy = BackendPolicy.record_quota(state.policy, evidence, state.run.id, System.system_time(:second))
    if policy != state.policy, do: persist_policy(state.dir, policy)
    run = Map.put(state.run, :quota, policy["claude_quota"])
    persist(run)
    {:noreply, %{state | policy: policy, run: run}}
  end

  def handle_info({:agent, pid, {:identity, backend, model}},
                  %{agent: pid, run: %{backend: backend}} = state) do
    run = Map.put(state.run, :model, model)
    persist(run)
    {:noreply, %{state | run: run}}
  end

  def handle_info({:agent, pid, {:session, id}}, %{agent: pid} = state) do
    run = Map.put(state.run, :session_id, id)
    persist(run)
    {:noreply, %{state | run: run}}
  end

  def handle_info({:agent, pid, {:activity, text}}, %{agent: pid} = state),
    do: {:noreply, %{state | run: Map.put(state.run, :activity, text)}}

  def handle_info({:agent, pid, {:ended, text}}, %{agent: pid} = state) do
    Process.demonitor(state.monitor, [:flush])
    run = Map.merge(state.run, %{state: "finished", result: text,
      ended_at: DateTime.to_iso8601(DateTime.utc_now())})
    persist(run)
    events = ExecutionEvents.append(state.dir, state.events, run)

    {:noreply,
     %{
       state
       | agent: nil,
         monitor: nil,
         run: run,
         events: events
     }}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{monitor: ref} = state) do
    run = Map.merge(state.run, %{state: "failed", error: inspect(reason),
      ended_at: DateTime.to_iso8601(DateTime.utc_now())})
    persist(run)
    events = ExecutionEvents.append(state.dir, state.events, run)
    {:noreply,
     %{
       state
       | agent: nil,
         monitor: nil,
         run: run,
         events: events
     }}
  end

  def handle_info(:shutdown, state) do
    System.stop(0)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp persist_policy(dir, policy) do
    path = Path.join(dir, "backends.json")
    File.write!(path <> ".tmp", JSON.encode!(policy))
    File.rename!(path <> ".tmp", path)
  end

  defp persist(run) do
    path = Path.join(run.artifacts, "turn.json")
    File.write!(path <> ".tmp", JSON.encode!(run))
    File.rename!(path <> ".tmp", path)
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, id)

  defp historical(id, state) do
    if not valid_id?(id), do: raise("Invalid turn ID")
    folder = Path.join([state.dir, "turns", id])
    if not File.dir?(folder), do: raise("Unknown turn: #{id}")
    if state.run[:id] == id do
      # Normalize keys to match persisted JSON without interning user input.
      Map.new(state.run, fn {key, value} -> {Atom.to_string(key), value} end)
    else
      run = case File.read(Path.join(folder, "turn.json")) do
        {:ok, bytes} -> JSON.decode!(bytes)
        {:error, :enoent} -> %{"state" => "unknown"}
        {:error, reason} -> raise("Cannot read turn #{id}: #{inspect(reason)}")
      end
      run = if run["state"] == "running",
        do: Map.merge(run, %{"state" => "unknown", "recorded_state" => "running"}),
        else: run
      Map.merge(run, %{"id" => id, "artifacts" => folder})
    end
  end

  defp turn_output(nil), do: %{answer: nil, recent_events: ""}
  defp turn_output(folder) do
    answer = case File.read(Path.join(folder, "answer.txt")) do
      {:ok, text} -> text
      {:error, :enoent} -> nil
      {:error, reason} -> raise("Cannot read turn answer: #{inspect(reason)}")
    end
    %{answer: answer, recent_events: recent(Path.join(folder, "stream.jsonl"))}
  end

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
