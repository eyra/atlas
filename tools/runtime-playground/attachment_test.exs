Code.require_file(Path.expand("../../clients/agent/lib/atlas_agent/runtime_session.ex", __DIR__))
Code.require_file(Path.join(__DIR__, "attachment.exs"))
ExUnit.start(seed: 0)

defmodule RuntimeAttachmentTest do
  use ExUnit.Case, async: true
  alias AtlasAgent.RuntimeSession, as: Session
  alias AtlasBFFContract.Wire.Runtime.AttachmentProtocol, as: Wire
  @target %{"environment" => "private", "machine" => "runtime-playground", "worker" => "breaker"}
  @execution %{"worker" => @target, "turn" => "t1", "attempt" => "a1"}
  @turn %{"execution" => @execution, "item" => "i1", "state" => "running"}
  @capabilities %{snapshot: true, control: false, guidance: false, output: false, replay: false}

  defp pending do
    session = Session.attach(@execution)
    {:ok, request, session} = Session.request(session, ["attach"], 0)
    {request, session}
  end

  defp result(request) do
    Wire.reply(:execution_attach, :result,
      id: request["id"],
      target: @target,
      execution: @execution,
      capabilities: @capabilities,
      turn: @turn
    )
  end

  test "generated profile keeps execution control separate from chat and lifecycle" do
    {request, _} = pending()
    assert request["execution"] == @execution
    assert request["channel"] == "control"

    assert {:ok, %{"turn" => "t1", "attempt" => "a1"}} =
             Wire.options(:runtime_attachment_options, ~w(--turn t1 --attempt a1))

    assert {:invalid, _} = Wire.options(:runtime_attachment_options, ~w(--turn t1))
    assert {:ok, :execution_attach, ^request} = Wire.decode_request(request)

    for words <- [["start"], ["stop"], ["mode", "crash"], ["please help"]] do
      assert {:error, _, _} = Session.request(Session.attach(@execution), words, 0)
    end

    for value <- [nil, "", " "] do
      assert_raise ArgumentError, fn -> Session.attach(Map.put(@execution, "attempt", value)) end
    end
  end

  test "every outer and nested identity binds to exact execution" do
    {request, session} = pending()
    frame = result(request)

    for bad <- [
          put_in(frame, ["target", "machine"], "other"),
          put_in(frame, ["execution", "turn"], "other"),
          put_in(frame, ["execution", "attempt"], "other"),
          put_in(frame, ["execution", "worker", "worker"], "other"),
          put_in(frame, ["turn", "execution", "attempt"], "other")
        ] do
      assert {:invalid, _, ^session} = Session.accept(session, JSON.encode!(bad), 1)
    end

    assert {:ok, :result, ^frame, next} = Session.accept(session, JSON.encode!(frame), 1)
    assert {:invalid, _, ^next} = Session.accept(next, JSON.encode!(frame), 2)
    assert Session.reconnect(next).execution == @execution
    assert Session.reconnect(next).pending == %{}
  end

  test "private policy refuses missing fencing, ended/replaced and foreign executions without projecting successors" do
    alias RuntimePlayground.Attachment, as: Policy
    snapshot = %{"turns" => [@turn]}
    assert {:ok, @turn} = Policy.select(snapshot, @execution, @target)

    assert {:error, "exact_execution_required"} =
             Policy.select(snapshot, Map.delete(@execution, "attempt"), @target)

    assert {:error, "stale_execution"} =
             Policy.select(snapshot, Map.put(@execution, "attempt", "old"), @target)

    assert {:error, "stale_execution"} =
             Policy.select(%{"turns" => [%{@turn | "state" => "ended"}]}, @execution, @target)

    assert {:error, "wrong_target"} =
             Policy.select(snapshot, put_in(@execution, ["worker", "machine"], "other"), @target)
  end

  test "typed errors consume IDs but foreign errors never do" do
    {request, session} = pending()

    error =
      Wire.reply(:execution_attach, :error,
        id: request["id"],
        target: @target,
        execution: @execution,
        error: %{code: "stale_execution", message: "refused", retryable: false}
      )

    assert {:invalid, _, ^session} =
             Session.accept(
               session,
               JSON.encode!(put_in(error, ["execution", "attempt"], "other")),
               1
             )

    assert {:ok, :error, ^error, next} = Session.accept(session, JSON.encode!(error), 1)
    assert next.pending == %{}
    assert {:invalid, _, ^next} = Session.accept(next, JSON.encode!(error), 1)
  end

  test "snapshots have no reply effect, reject replay, expiry and backpressure remain bounded" do
    {_, session} = pending()

    event =
      Wire.event(:execution_snapshot,
        sequence: 1,
        target: @target,
        execution: @execution,
        capabilities: @capabilities,
        turn: @turn
      )

    assert {:ok, :event, ^event, next} = Session.accept(session, JSON.encode!(event), 1)
    assert next.pending == session.pending
    assert {:invalid, _, ^next} = Session.accept(next, JSON.encode!(event), 2)

    full =
      Enum.reduce(2..Session.limit(), session, fn _, s ->
        {:ok, _, s} = Session.request(s, ["status"], 0)
        s
      end)

    assert {:error, :backpressure, ^full} = Session.request(full, ["status"], 1)
    {empty, ids} = Session.expire(full, Session.timeout())
    assert length(ids) == Session.limit()
    assert empty.pending == %{}
  end
end
