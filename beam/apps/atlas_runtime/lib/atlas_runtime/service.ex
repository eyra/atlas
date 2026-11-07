defmodule AtlasRuntime.Service do
  use GenServer
  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.BackendPolicy
  alias AtlasRuntime.CommandAdmissions
  alias AtlasRuntime.ExecutionEvents
  alias AtlasRuntime.QuestionRecords

  def start(dir), do: GenServer.start_link(__MODULE__, dir, name: __MODULE__)

  def init(dir) do
    policy = case File.read(Path.join(dir, "backends.json")) do
      {:ok, bytes} -> BackendPolicy.validate!(JSON.decode!(bytes))
      {:error, :enoent} -> BackendPolicy.empty()
      {:error, reason} -> raise("Cannot read backend policy: #{inspect(reason)}")
    end
    events = QuestionRecords.recover(dir, ExecutionEvents.open(dir))
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
    {:ok, %{dir: dir, policy: policy, events: events, workers: %{}, stopping: false}}
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
        error in [QuestionRecords.StorageError, CommandAdmissions.StorageError] -> reraise error, __STACKTRACE__
        error -> {%{command_error: Exception.message(error)}, state, false}
      catch
        :exit, why -> {%{command_error: "Operation not confirmed: #{inspect(why)}"}, state, false}
      end

    next = record_changes(state, next)
    reply =
      case {request, reply} do
        {_, {:admission, record, run}} ->
          state.dir |> CommandAdmissions.accept(record, run) |> CommandAdmissions.public()
        {%{"command" => "stop"}, %{worker_id: id}} ->
          Map.get(next.workers, id, %{run: reply}).run
        {%{"command" => "service-stop"}, %{workers: _}} ->
          reply = Map.put(reply, :workers, worker_runs(next))
          if Map.has_key?(reply, :agent), do: Map.put(reply, :agent, sole_run(next)), else: reply
        _ -> reply
      end
    {:reply, {reply, shutdown?}, next}
  end

  defp command(%{"request_id" => _} = request, state) do
    canonical = CommandAdmissions.canonical(request)
    request_id = request["request_id"]

    case CommandAdmissions.load(state.dir, request_id) do
      nil ->
        if state.stopping, do: raise("Runtime service is stopping")
        request = Map.delete(request, "request_id")
        {worker_id, saved} = select_worker(request, state)
        worker = Map.get(state.workers, worker_id, idle_worker(worker_id))
        worker_command(request, worker_id, worker, saved, state, {request_id, canonical})

      record ->
        if record["request"] != canonical,
          do: raise(ArgumentError, "Conflicting request ID: #{request_id}")
        {CommandAdmissions.public(record), state, false}
    end
  end

  defp command(_, %{stopping: true}), do: raise("Runtime service is stopping")

  defp command(%{"command" => "question"} = request, state) do
    question_selectors!(request, [])
    record = owned_question!(state, request)
    {QuestionRecords.public(record), state, false}
  end

  defp command(%{"command" => "answer"} = request, state) do
    question_selectors!(request, ["answers"])
    record = owned_question!(state, request)
    if record["admission"] == "accepted" do
      if record["answers"] != request["answers"], do: raise("Conflicting answer: question already admitted")
      {QuestionRecords.evidence(record), state, false}
    else
      worker = state.workers[request["worker_id"]] || raise("Unknown worker: #{request["worker_id"]}")
      if not record["active"] or not is_pid(worker.agent) or
           worker.run.state != "running" or worker.run.id != request["turn_id"],
        do: raise("Answer requires the current active worker turn")
      if worker.run[:questions_enabled] != true or worker.run[:backend] != "claude",
        do: raise("Questions are not enabled for this turn")
      question = worker.run[:pending_question]
      if is_nil(question) or question.id != request["question_id"], do: raise("No matching pending question")
      if Native.validate_answers(%{questions: record["original_input"]["questions"]}, request["answers"]) != :ok,
        do: raise("Invalid answers for the pending question")

      # Admission and its journal checkpoint must precede the only native send.
      {record, events} = QuestionRecords.admit(state.dir, state.events, record, request["answers"])
      {record, events} =
        case send_answer(worker.agent, request["question_id"], request["answers"]) do
          {:ok, %{status: "delivered"}} -> QuestionRecords.delivered(state.dir, events, record)
          _ -> {record, events}
        end
      evidence = QuestionRecords.evidence(record)
      run = Map.merge(worker.run, %{pending_question: nil, last_answer: evidence})
      {evidence, put_worker(%{state | events: events}, request["worker_id"], %{worker | run: run}), false}
    end
  end


  defp command(%{"command" => name} = request, state)
       when name in ["start", "status", "output", "stop", "continue"] do
    {worker_id, saved} = select_worker(request, state)
    worker = Map.get(state.workers, worker_id, idle_worker(worker_id))
    worker_command(request, worker_id, worker, saved, state)
  end

  defp command(%{"worker_id" => _}, _),
    do: raise("This command does not accept a worker")

  defp command(%{"command" => "service-status"}, state) do
    reply = %{service: "running", pid: System.pid(), workers: worker_runs(state)}
    run = sole_run(state)
    {if(run, do: Map.put(reply, :agent_state, run.state), else: reply), state, false}
  end

  defp command(%{"command" => "service-stop"}, state) do
    {workers, errors} =
      Enum.reduce(Enum.sort(state.workers), {state.workers, []}, fn {id, worker}, {workers, errors} ->
        try do
          {Map.put(workers, id, stop(worker)), errors}
        rescue
          error -> {workers, errors ++ ["#{id}: #{Exception.message(error)}"]}
        catch
          :exit, reason -> {workers, errors ++ ["#{id}: #{inspect(reason)}"]}
        end
      end)
    next = %{state | workers: workers, stopping: errors == []}
    if errors == [] do
      reply = %{service: "stopping", workers: worker_runs(next)}
      run = sole_run(next)
      {if(run, do: Map.put(reply, :agent, run), else: reply), next, true}
    else
      {%{command_error: "Stop not confirmed: " <> Enum.join(errors, "; "),
         workers: worker_runs(next)}, next, false}
    end
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

  defp command(_, _), do: raise("Unknown or malformed command")
  defp question_selectors!(request, extra) do
    fields = ["command", "worker_id", "turn_id", "question_id"] ++ extra
    if Enum.sort(Map.keys(request)) != Enum.sort(fields),
      do: raise("#{String.capitalize(request["command"])} requires exactly worker_id, turn_id, question_id#{if extra == [], do: "", else: " and answers"}")
    if not valid_worker_id?(request["worker_id"]), do: raise("Invalid worker ID")
    if not valid_id?(request["turn_id"]), do: raise("Invalid turn ID")
    if not is_binary(request["question_id"]) or
         not Regex.match?(~r/\Aquestion-[0-9a-f]{1,64}\z/, request["question_id"]),
      do: raise("Invalid question ID")
  end

  defp owned_question!(state, request) do
    record = QuestionRecords.load(state.dir, request["turn_id"], request["question_id"]) ||
      raise("Question record unavailable; no matching recorded question")
    if record["worker_id"] != request["worker_id"],
      do: raise("Question belongs to worker #{record["worker_id"]}, not #{request["worker_id"]}")
    record
  end

  defp send_answer(agent, question_id, answers) do
    Native.answer(agent, question_id, answers)
  rescue
    _ -> {:error, :delivery_unknown}
  catch
    :exit, _ -> {:error, :delivery_unknown}
  end


  defp worker_command(request, id, worker, saved, state, admission \\ nil)

  defp worker_command(%{"command" => "status"}, _id, worker, saved, state, _admission),
    do: {saved || worker.run, state, false}

  defp worker_command(%{"command" => "output"}, _id, worker, saved, state, _admission) do
    run = saved || worker.run
    {Map.merge(run, turn_output(run[:artifacts] || run["artifacts"])), state, false}
  end

  defp worker_command(%{"command" => "stop"}, id, worker, _saved, state, _admission) do
    next = stop(worker)
    workers = if Map.has_key?(state.workers, id), do: Map.put(state.workers, id, next), else: state.workers
    {next.run, %{state | workers: workers}, false}
  end

  defp worker_command(%{"command" => "start", "repository" => url, "branch" => branch,
                 "permissions" => "dedicated-repository", "assignment" => assignment} = request,
                 worker_id, worker, _saved, state, admission)
       when is_binary(url) and is_binary(branch) and is_binary(assignment) do
    if worker.agent, do: raise("Worker #{worker_id} already has an active agent; use status or stop")
    selection = select_backend(request, state)
    if Map.keys(request) -- ["command", "repository", "branch", "permissions", "assignment", "backend", "worker_id", "questions_enabled"] != [],
      do: raise("Repository provisioning cannot be combined with cwd or sandbox")
    prepared = Native.repository_request(Path.join([state.dir, "workers", worker_id]), url, branch)
    scope = prepared["permissions"]
    start_turn(assignment, scope["root"], nil, scope, nil, state, worker_id, prepared["repository"], selection, nil, Map.get(request, "questions_enabled", false), admission)
  end

  defp worker_command(%{"command" => "start", "cwd" => cwd, "assignment" => assignment} = request,
                      worker_id, worker, _saved, state, admission)
       when is_binary(cwd) and is_binary(assignment) do
    if worker.agent, do: raise("Worker #{worker_id} already has an active agent; use status or stop")
    if Map.keys(request) -- ["command", "cwd", "assignment", "permissions", "sandbox", "backend", "worker_id", "questions_enabled"] != [],
      do: raise("Unknown start fields")
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
    start_turn(assignment, cwd, sandbox, scope, nil, state, worker_id, nil, selection, nil, Map.get(request, "questions_enabled", false), admission)
  end

  defp worker_command(%{"command" => "continue", "assignment" => assignment} = request,
                      worker_id, worker, saved, state, admission)
       when is_binary(assignment) do
    if Map.keys(request) -- ["command", "assignment", "turn_id", "worker_id"] != [],
      do: raise("Continue accepts only an assignment, worker and optional turn ID; working directory and permissions cannot change")
    if worker.agent, do: raise("Worker #{worker_id} already has an active agent; wait for completion or stop it")
    run = saved || string_keys(worker.run)
    backend = Map.get(run, "backend", "codex")
    if backend not in ["codex", "claude"], do: raise("Unknown saved backend; sessions cannot switch vendors")
    questions_enabled = questions_enabled!(run, backend)
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
    start_turn(assignment, cwd, sandbox, scope, session, state, worker_id, run["repository"], selection, context, questions_enabled, admission, run["id"])
  end

  defp worker_command(_, _, _, _, _, _), do: raise("Unknown or malformed command")

  defp select_worker(request, state) do
    explicit? = Map.has_key?(request, "worker_id")
    requested = request["worker_id"]
    if explicit? and not valid_worker_id?(requested), do: raise("Invalid worker ID")
    saved =
      if Map.has_key?(request, "turn_id") do
        if request["command"] not in ["output", "continue"],
          do: raise("This command does not accept a turn ID")
        historical(request["turn_id"], state)
      end

    worker_id =
      cond do
        saved ->
          if explicit? and requested != saved["worker_id"],
            do: raise("Turn belongs to worker #{saved["worker_id"]}, not #{requested}")
          saved["worker_id"]
        explicit? -> requested
        map_size(state.workers) == 0 -> "default"
        map_size(state.workers) == 1 -> state.workers |> Map.keys() |> hd()
        true -> raise("Multiple workers are registered; specify --worker")
      end

    if explicit? and is_nil(saved) and request["command"] != "start" and
         not Map.has_key?(state.workers, worker_id),
      do: raise("Unknown worker: #{worker_id}")
    {worker_id, saved}
  end

  defp valid_worker_id?(id),
    do: is_binary(id) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, id)

  defp idle_worker(id), do: %{agent: nil, monitor: nil, run: %{worker_id: id, state: "idle"}}
  defp worker_runs(state), do: Map.new(state.workers, fn {id, worker} -> {id, worker.run} end)
  defp string_keys(run), do: Map.new(run, fn {key, value} -> {Atom.to_string(key), value} end)

  defp sole_run(%{workers: workers}) when map_size(workers) == 0, do: idle_worker("default").run
  defp sole_run(%{workers: workers}) when map_size(workers) == 1 do
    {_id, worker} = Enum.at(workers, 0)
    worker.run
  end
  defp sole_run(_), do: nil

  defp select_backend(request, state) do
    if Map.has_key?(request, "backend") and is_nil(request["backend"]),
      do: raise("Backend must be codex or claude")
    selection = BackendPolicy.select(state.policy, request["backend"], request, System.system_time(:second))
    questions_enabled!(request, selection["selected"]["backend"])
    selection
  end

  defp questions_enabled!(settings, backend) do
    enabled = Map.get(settings, "questions_enabled", false)
    if not is_boolean(enabled), do: raise("questions_enabled must be a boolean")
    if enabled and backend != "claude", do: raise("Questions are supported only by Claude")
    enabled
  end

  defp start_turn(assignment, cwd, sandbox, scope, session, state, worker_id, repository, selection, context, questions_enabled, admission, source_turn_id \\ nil) do
    backend = selection["selected"]["backend"]
    model = selection["selected"]["model"]
    if (not File.dir?(cwd) and is_nil(repository)) or String.trim(assignment) == "",
      do: raise("An existing working directory and nonempty assignment are required")
    cwd = Native.workspace_path(cwd)
    Enum.each(state.workers, fn {id, worker} ->
      if not is_nil(worker.agent) and overlapping_paths?(cwd, worker.run.cwd),
        do: raise("Workspace overlaps active worker #{id}")
    end)

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
      "resume_context" => context,
      "questions_enabled" => questions_enabled
    }

    run = %{
      id: key,
      worker_id: worker_id,
      backend: backend,
      questions_enabled: questions_enabled,
      pending_question: nil,
      last_answer: nil,
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
    run = if admission, do: Map.put(run, :request_id, elem(admission, 0)), else: run

    record =
      if admission do
        {request_id, canonical} = admission
        binding = %{
          "worker_id" => worker_id,
          "source_turn_id" => source_turn_id,
          "cwd" => run.cwd,
          "sandbox" => sandbox,
          "permissions" => scope,
          "repository" => repository,
          "backend" => backend,
          "model" => model,
          "session_id" => session,
          "questions_enabled" => questions_enabled
        }
        CommandAdmissions.reserve(state.dir, request_id, canonical, binding, key, run)
      end

    result =
      try do
        Native.start(%{key: key}, agent: settings, turns_dir: turns)
      rescue
        error ->
          if record, do: {:error, error}, else: reraise(error, __STACKTRACE__)
      catch
        :exit, reason ->
          if record, do: {:error, reason}, else: exit(reason)
      end

    case result do
      {:ok, pid} ->
        worker = %{agent: pid, monitor: Process.monitor(pid), run: run}
        next = %{state | workers: Map.put(state.workers, worker_id, worker)}
        reply = if record, do: {:admission, record, run}, else: run
        {reply, next, false}

      {:error, why} ->
        if record,
          do: {CommandAdmissions.public(record), state, false},
          else: raise("#{backend} start failed: #{inspect(why)}")
    end
  end


  defp stop(%{agent: nil} = state), do: state

  defp stop(state) do
    :ok = Native.stop(state.agent)
    Process.demonitor(state.monitor, [:flush])
    %{state | agent: nil, monitor: nil,
      run: Map.merge(state.run, %{state: "stopped", pending_question: nil, ended_at: DateTime.to_iso8601(DateTime.utc_now())})}
  end

  def handle_info({:agent, pid, message}, state) when is_pid(pid) do
    case Enum.find(state.workers, fn {_id, worker} -> worker.agent == pid end) do
      nil -> {:noreply, state}
      {id, worker} -> {:noreply, agent_message(message, id, worker, state)}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.workers, fn {_id, worker} ->
           worker.agent == pid and worker.monitor == ref and is_reference(ref)
         end) do
      nil -> {:noreply, state}
      {id, worker} ->
        run = Map.merge(worker.run, %{state: "failed", pending_question: nil, error: inspect(reason),
          ended_at: DateTime.to_iso8601(DateTime.utc_now())})
        next = put_worker(state, id, %{worker | agent: nil, monitor: nil, run: run})
        {:noreply, record_changes(state, next)}
    end
  end

  def handle_info(:shutdown, state) do
    System.stop(0)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp agent_message({:question, question}, id,
         %{run: %{state: "running", backend: "claude", questions_enabled: true}} = worker, state) do
    if is_nil(worker.run[:pending_question]) do
      {record, events} = QuestionRecords.create(state.dir, state.events, worker.run, question)
      question = Map.merge(question, %{record_ref: record["record_ref"], revision: record["revision"]})
      update_run(%{state | events: events}, id, worker, Map.put(worker.run, :pending_question, question))
    else
      state
    end
  end

  defp agent_message({:answer, %{question_id: question_id, status: status}}, id, worker, state)
       when status in ["delivered", "processed"] do
    record = QuestionRecords.load(state.dir, worker.run.id, question_id)
    if record && record["worker_id"] == id && record["admission"] == "accepted" do
      {record, events} =
        if status == "processed",
          do: QuestionRecords.processed(state.dir, state.events, record),
          else: QuestionRecords.delivered(state.dir, state.events, record)
      evidence = QuestionRecords.evidence(record)
      pending = worker.run[:pending_question]
      pending = if pending && pending.id == question_id, do: nil, else: pending
      last = worker.run[:last_answer]
      last = if is_nil(last) or last.question_id == question_id, do: evidence, else: last
      run = Map.merge(worker.run, %{pending_question: pending, last_answer: last})
      update_run(%{state | events: events}, id, worker, run)
    else
      state
    end
  end

  defp agent_message({:repository, repository}, id, worker, state),
    do: update_run(state, id, worker, Map.put(worker.run, :repository, repository))

  defp agent_message({:quota, evidence}, id, %{run: %{backend: "claude"}} = worker, state) do
    policy = BackendPolicy.record_quota(state.policy, evidence, worker.run.id, System.system_time(:second))
    if policy != state.policy, do: persist_policy(state.dir, policy)
    update_run(%{state | policy: policy}, id, worker, Map.put(worker.run, :quota, policy["claude_quota"]))
  end

  defp agent_message({:identity, backend, model}, id, %{run: %{backend: backend}} = worker, state),
    do: update_run(state, id, worker, Map.put(worker.run, :model, model))

  defp agent_message({:session, session}, id, worker, state),
    do: update_run(state, id, worker, Map.put(worker.run, :session_id, session))

  defp agent_message({:activity, text}, id, worker, state),
    do: put_worker(state, id, %{worker | run: Map.put(worker.run, :activity, text)})

  defp agent_message({:ended, text}, id, worker, state) do
    Process.demonitor(worker.monitor, [:flush])
    run = Map.merge(worker.run, %{state: "finished", pending_question: nil, result: text,
      ended_at: DateTime.to_iso8601(DateTime.utc_now())})
    next = put_worker(state, id, %{worker | agent: nil, monitor: nil, run: run})
    record_changes(state, next)
  end

  defp agent_message(_, _, _, state), do: state

  defp put_worker(state, id, worker),
    do: %{state | workers: Map.put(state.workers, id, worker)}

  defp update_run(state, id, worker, run),
    do: record_changes(state, put_worker(state, id, %{worker | run: run}))

  defp record_changes(previous, next) do
    Enum.reduce(Enum.sort(next.workers), next, fn {id, worker}, acc ->
      old = Map.get(previous.workers, id, idle_worker(id)).run
      {worker, acc} =
        if worker.run[:id] && worker.run.state in ["stopped", "finished", "failed"] &&
             {worker.run[:id], worker.run.state} != {old[:id], old.state} do
          events = QuestionRecords.invalidate_turn(acc.dir, acc.events, worker.run.id, worker.run.state)
          worker =
            case worker.run[:last_answer] do
              %{question_id: question_id} ->
                record = QuestionRecords.load(acc.dir, worker.run.id, question_id)
                if record, do: %{worker | run: Map.put(worker.run, :last_answer, QuestionRecords.evidence(record))},
                  else: worker
              _ -> worker
            end
          {worker, put_worker(%{acc | events: events}, id, worker)}
        else
          {worker, acc}
        end
      if worker.run != old, do: persist(worker.run)
      if {worker.run[:id], worker.run.state} != {old[:id], old.state} do
        %{acc | events: ExecutionEvents.append(acc.dir, acc.events, worker.run)}
      else
        acc
      end
    end)
  end

  defp overlapping_paths?(left, right) do
    left == right or String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/") or left == "/" or right == "/"
  end

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
    current = Enum.find_value(state.workers, fn {_worker_id, worker} ->
      if worker.run[:id] == id, do: worker.run
    end)
    if current do
      # Normalize keys to match persisted JSON without interning user input.
      string_keys(current)
    else
      run = case File.read(Path.join(folder, "turn.json")) do
        {:ok, bytes} -> JSON.decode!(bytes)
        {:error, :enoent} -> %{"state" => "unknown"}
        {:error, reason} -> raise("Cannot read turn #{id}: #{inspect(reason)}")
      end
      run = Map.put_new(run, "worker_id", "default")
      run = run |> Map.put_new("questions_enabled", false) |> Map.put("pending_question", nil)
      if not valid_worker_id?(run["worker_id"]), do: raise("Invalid saved worker ID")
      run =
        case run["last_answer"] do
          %{"question_id" => question_id, "record_ref" => _} ->
            if not is_binary(question_id) or not Regex.match?(~r/\Aquestion-[0-9a-f]{1,64}\z/, question_id),
              do: raise(QuestionRecords.StorageError, message: "Invalid saved question reference")
            record = QuestionRecords.load(state.dir, id, question_id) ||
              raise(QuestionRecords.StorageError, message: "Saved question record is missing")
            if record["worker_id"] != run["worker_id"],
              do: raise(QuestionRecords.StorageError, message: "Saved question ownership changed")
            Map.put(run, "last_answer", string_keys(QuestionRecords.evidence(record)))
          _ -> run
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