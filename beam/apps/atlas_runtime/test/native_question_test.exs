defmodule AtlasRuntime.NativeQuestionTest do
  use ExUnit.Case, async: false
  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.{BackendPolicy, ExecutionEvents, Service}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(bin)
    File.mkdir_p!(workspace)
    executable = Path.join(bin, "claude")
    File.write!(executable, "#!#{System.find_executable("python3")}\n" <> ~S"""
    import json, os, sys, time
    with open('native.pid', 'w') as file:
        file.write(str(os.getpid()))
    def emit(event):
        print(json.dumps(event), flush=True)
    def arg(name, default=None):
        return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default
    session = arg('--session-id', arg('--resume', '15113671-40b9-4677-8b2b-c6c1180db993'))
    model = arg('--model', 'claude-sonnet-4-6')
    host = '--permission-prompt-tool' in sys.argv
    init = {'type':'system', 'subtype':'init', 'session_id':session, 'model':model,
            'tools':['Read','Glob','Grep','AskUserQuestion'] if host else ['Read','Glob','Grep']}
    result = {'type':'result', 'session_id':session, 'subtype':'success', 'is_error':False, 'result':'done'}
    if not host:
        emit(init)
        emit(result)
        sys.exit(0)
    initialize = json.loads(sys.stdin.readline())
    emit({'type':'control_response', 'response':{'subtype':'success', 'request_id':initialize['request_id'], 'response':{}}})
    assignment = json.loads(sys.stdin.readline())
    emit(init)
    question_input = {'questions':[{'question':'Choose?', 'header':'Choice', 'multiSelect':False,
                                   'options':[{'label':'A','description':'A'}, {'label':'B','description':'B'}]}]}
    emit({'type':'assistant', 'session_id':session, 'message':{'model':model, 'content':[
          {'type':'tool_use', 'id':'tool-1', 'name':'AskUserQuestion', 'input':question_input}]}})
    emit({'type':'control_request', 'request_id':'request-1', 'request':{
          'subtype':'can_use_tool', 'tool_name':'AskUserQuestion', 'input':question_input,
          'tool_use_id':'tool-1', 'requires_user_interaction':True}})
    response = json.loads(sys.stdin.readline())
    with open('received-answer.json', 'w') as file:
        json.dump(response, file)
    while not os.path.exists('process-answer'):
        time.sleep(0.01)
    emit({'type':'user', 'session_id':session, 'message':{'content':[
          {'type':'tool_result', 'tool_use_id':'tool-1', 'content':'processed'}]}})
    emit(result)
    assert sys.stdin.read() == ''
    """)
    File.chmod!(executable, 0o700)
    previous = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)
    %{executable: executable, workspace: workspace,
      state: %{dir: dir, policy: BackendPolicy.empty(), events: ExecutionEvents.open(dir), workers: %{}, stopping: false}}
  end

  defp launch(context, changes \\ %{}) do
    settings = Map.merge(%{"backend" => "claude", "command" => context.executable,
                          "workspace" => context.workspace, "goal" => "Choose", "questions_enabled" => true}, changes)
    Native.start(%{key: "question-turn"}, agent: settings, turns_dir: Path.join(context.tmp_dir, "turns"))
  end

  defp cleanup(pid), do: on_exit(fn -> if Process.alive?(pid), do: Native.stop(pid) end)

  test "delivery acknowledges stdin, processing requires native tool_result, duplicate never writes", context do
    {:ok, pid} = launch(context)
    cleanup(pid)
    ref = Process.monitor(pid)
    assert_receive {:agent, ^pid, {:question, question}}, 5_000
    assert question.questions |> hd() |> Map.fetch!("question") == "Choose?"
    assert {:error, :no_matching_pending_question} = Native.answer(pid, "question-dead", %{"Choose?" => "A"})
    assert {:error, :invalid_answers} = Native.answer(pid, question.id, %{"Choose?" => " "})
    assert {:ok, %{question_id: id, status: "delivered"}} = Native.answer(pid, question.id, %{"Choose?" => "fresh answer"})
    assert id == question.id
    assert_receive {:agent, ^pid, {:answer, %{question_id: ^id, status: "delivered"}}}
    refute_receive {:agent, ^pid, {:answer, %{status: "processed"}}}, 30
    assert :sys.get_state(pid).pending_question == nil
    assert :sys.get_state(pid).last_answer.status == "delivered"
    assert {:error, :no_matching_pending_question} = Native.answer(pid, id, %{"Choose?" => "duplicate"})
    File.write!(Path.join(context.workspace, "process-answer"), "")
    assert_receive {:agent, ^pid, {:answer, %{question_id: ^id, status: "processed"}}}, 5_000
    assert_receive {:agent, ^pid, {:ended, "done"}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:error, _} = Native.answer(pid, id, %{"Choose?" => "late"})
    response = Path.join(context.workspace, "received-answer.json") |> File.read!() |> JSON.decode!()
    assert response["response"]["response"]["updatedInput"]["answers"] == %{"Choose?" => "fresh answer"}
    refute Map.has_key?(response["response"]["response"], "updatedPermissions")
  end

  test "pending stop and native loss refuse late answers", context do
    {:ok, pid} = launch(context)
    assert_receive {:agent, ^pid, {:question, question}}, 5_000
    assert :ok = Native.stop(pid)
    assert {:error, _} = Native.answer(pid, question.id, %{"Choose?" => "late"})
    refute File.exists?(Path.join(context.workspace, "received-answer.json"))

    {:ok, pid} = launch(context)
    assert_receive {:agent, ^pid, {:question, question}}, 5_000
    ref = Process.monitor(pid)
    native_pid = context.workspace |> Path.join("native.pid") |> File.read!()
    assert {_, 0} = System.cmd("kill", ["-KILL", native_pid])
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    assert {:error, _} = Native.answer(pid, question.id, %{"Choose?" => "late"})
  end

  test "waiting answer callers are cancelled on stop and termination", _context do
    for terminal <- [:stop, :terminate] do
      tag = make_ref()
      timer = Process.send_after(self(), :unused_timeout, 60_000)
      state = %{port: nil, pending_question: %{id: "question-ab"},
                answer_waiter: {"question-ab", {self(), tag}, timer}, stopping: nil}
      case terminal do
        :stop ->
          assert {:noreply, %{pending_question: nil, answer_waiter: nil}} =
                   Native.handle_call(:stop, {self(), make_ref()}, state)
        :terminate -> Native.terminate(:lost, state)
      end
      assert_receive {^tag, {:error, :native_question_cancelled}}
    end
    assert {:error, :invalid_answer} = Native.answer(nil, "question-ab", %{})
    assert {:error, :invalid_answer} = Native.answer(self(), nil, %{})
  end

  test "runner acknowledgements stay correlated and rejection never becomes delivery", _context do
    port = make_ref()
    tag = make_ref()
    timer = Process.send_after(self(), :unused_timeout, 60_000)
    question = %{id: "question-ab", questions: [%{"question" => "Choose?"}]}
    state = %{port: port, owner: self(), partial: "", pending_question: question,
              answer_waiter: {question.id, {self(), tag}, timer}, last_answer: nil, stopping: nil}
    event = fn type, id, extra ->
      record = Map.merge(%{"type" => type, "question_id" => id}, extra)
      {port, {:data, {:eol, JSON.encode!(record)}}}
    end
    assert {:noreply, ^state} =
             Native.handle_info(event.("runtime.answer_processed", question.id, %{}), state)
    assert {:noreply, ^state} =
             Native.handle_info(event.("runtime.answer_delivered", "question-dead", %{}), state)
    assert {:noreply, rejected} =
             Native.handle_info(event.("runtime.answer_rejected", question.id, %{"error" => "refused"}), state)
    assert_receive {^tag, {:error, "refused"}}
    assert rejected.pending_question == question
    assert rejected.answer_waiter == nil
    assert rejected.last_answer == nil
    refute_received {:agent, _, {:answer, _}}
    timeout_state = %{state | answer_waiter: {question.id, {self(), tag}, timer}}
    assert {:stop, :answer_delivery_timeout, %{pending_question: nil, answer_waiter: nil}} =
             Native.handle_info({:answer_timeout, question.id}, timeout_state)
    assert_receive {^tag, {:error, :native_question_cancelled}}
  end

  test "answer bounds use UTF-8 bytes and the complete encoded object", _context do
    questions = Enum.map(1..4, &%{"question" => "Question #{&1}?"})
    question = %{questions: questions}
    assert :ok = Native.validate_answers(question, Map.new(questions, &{&1["question"], "yes"}))
    assert {:error, :invalid_answers} = Native.validate_answers(question, Map.new(questions, &{&1["question"], String.duplicate("x", 4096)}))
    assert {:error, :invalid_answers} = Native.validate_answers(%{questions: [%{"question" => "Q?"}]}, %{"Q?" => String.duplicate("é", 2049)})
    assert {:error, :invalid_answers} = Native.validate_answers(%{questions: [%{"question" => "Q?"}]}, %{"Q?" => <<255>>})
  end

  defp call(state, request) do
    {:reply, {reply, false}, next} = Service.handle_call(request, {self(), make_ref()}, state)
    refute Map.has_key?(reply, :command_error), inspect(reply)
    {reply, next}
  end

  defp await_run(state, predicate) do
    if predicate.(state.workers["alpha"].run) do
      state
    else
      receive do
        message ->
          {:noreply, next} = Service.handle_info(message, state)
          await_run(next, predicate)
      after
        5_000 -> flunk("Missing native lifecycle evidence")
      end
    end
  end

  test "service carries capability through saved continuation and exposes only delivery evidence", context do
    request = %{"command" => "start", "worker_id" => "alpha", "backend" => "claude",
                "cwd" => context.workspace, "assignment" => "Choose", "questions_enabled" => true}
    {run, state} = call(context.state, request)
    cleanup(state.workers["alpha"].agent)
    assert run.questions_enabled
    state = await_run(state, & &1.pending_question)
    pending = state.workers["alpha"].run.pending_question
    answer = %{"command" => "answer", "worker_id" => "alpha", "turn_id" => run.id,
               "question_id" => pending.id, "answers" => %{"Choose?" => "fresh"}}
    {evidence, state} = call(state, answer)
    assert evidence.status == "delivered"
    assert state.workers["alpha"].run.pending_question == nil
    assert state.workers["alpha"].run.last_answer.status == "delivered"
    File.write!(Path.join(context.workspace, "process-answer"), "")
    state = await_run(state, &(&1.state == "finished"))
    original = state.workers["alpha"].run
    assert original.last_answer.status == "processed"
    {continued, state} = call(state, %{"command" => "continue", "worker_id" => "alpha", "turn_id" => run.id, "assignment" => "Choose again"})
    cleanup(state.workers["alpha"].agent)
    assert continued.questions_enabled
    assert continued.session_id == original.session_id
    assert continued.requested_model == original.model
    assert continued.cwd == original.cwd
    assert continued.sandbox == original.sandbox
    assert continued.pending_question == nil
    assert continued.last_answer == nil
    state = await_run(state, & &1.pending_question)
    assert state.workers["alpha"].run.pending_question.id != pending.id
    {stopped, _} = call(state, %{"command" => "stop", "worker_id" => "alpha"})
    assert stopped.pending_question == nil
  end

  test "default and legacy continuation keep questions disabled", context do
    request = %{"command" => "start", "worker_id" => "alpha", "backend" => "claude",
                "cwd" => context.workspace, "assignment" => "Read"}
    {run, state} = call(context.state, request)
    cleanup(state.workers["alpha"].agent)
    refute run.questions_enabled
    state = await_run(state, &(&1.state == "finished"))
    saved = state.workers["alpha"].run
    path = Path.join(saved.artifacts, "turn.json")
    File.write!(path, saved |> Map.delete(:questions_enabled) |> JSON.encode!())
    restarted = %{state | workers: %{}}
    {continued, state} = call(restarted, %{"command" => "continue", "turn_id" => run.id, "assignment" => "Read again"})
    cleanup(state.workers["alpha"].agent)
    refute continued.questions_enabled
    state = await_run(state, &(&1.state == "finished"))
    assert state.workers["alpha"].run.pending_question == nil
  end
end
