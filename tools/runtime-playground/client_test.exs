Code.require_file(Path.expand("../../clients/agent/lib/atlas_agent/runtime_session.ex", __DIR__))
# Only the actual Client module and generated codecs; no Server, worker or application starts.
source = File.read!(Path.join(__DIR__, "playground.exs"))
[_, client] = String.split(source, "defmodule RuntimePlayground.Client do", parts: 2)
[client, _] = String.split(client, "\ncase System.argv() do", parts: 2)
Code.compile_string("defmodule RuntimePlayground.Client do" <> client)
ExUnit.start(seed: 0)

defmodule RuntimePlayground.ClientTest do
  use ExUnit.Case, async: true
  alias RuntimePlayground.Client.Session
  alias AtlasBFFContract.Wire.Runtime.Protocol, as: Wire
  @target %{"environment" => "private", "machine" => "runtime-playground", "worker" => "breaker"}
  @status %{
    target: @target,
    engine_running: false,
    capabilities: %{controls: %{start: true, stop: true, status: true, stub_mode: true}},
    turns: []
  }

  defp request do
    {:ok, frame, session} = Session.request(Session.new(@target), ["status"], 0)
    {frame, session}
  end

  defp result(frame, status \\ @status),
    do: Wire.reply(:runtime_status, :result, id: frame["id"], target: @target, status: status)

  test "all terminal results and errors consume their ID; unknown or duplicate replies are refused" do
    for variant <- [:result, :error] do
      {request, session} = request()

      frame =
        if variant == :result,
          do: result(request),
          else:
            Wire.reply(:runtime_status, :error,
              id: request["id"],
              error: %{code: "refused", message: "fixture", retryable: false}
            )

      assert {:ok, ^variant, ^frame, next} = Session.accept(session, JSON.encode!(frame), 1)
      assert next.pending == %{}
      assert {:invalid, _, ^next} = Session.accept(next, JSON.encode!(frame), 2)

      assert {:invalid, _, ^session} =
               Session.accept(session, JSON.encode!(%{frame | "id" => "unknown"}), 1)
    end
  end

  test "outer, nested status and execution identities bind every message to the selected session" do
    {request, session} = request()
    reply = result(request)
    turn = %{execution: %{worker: @target, turn: "turn-1"}, item: "item", state: "running"}

    event =
      Wire.event(:runtime_status_event,
        sequence: 1,
        target: @target,
        status: Map.put(@status, :turns, [turn])
      )

    error =
      Wire.reply(:runtime_status, :error,
        id: request["id"],
        target: @target,
        error: %{code: "refused", message: "fixture", retryable: false}
      )

    for key <- ~w(environment machine worker) do
      foreign = Map.put(@target, key, "foreign")

      for frame <- [
            put_in(reply, ["target"], foreign),
            put_in(reply, ["status", "target"], foreign),
            put_in(error, ["target"], foreign),
            put_in(event, ["target"], foreign),
            put_in(event, ["status", "target"], foreign),
            put_in(event, ["status", "turns"], [
              put_in(Wire.model(:runtime_turn, turn), ["execution", "worker"], foreign)
            ]),
            put_in(reply, ["status", "turns"], [
              put_in(Wire.model(:runtime_turn, turn), ["execution", "worker"], foreign)
            ])
          ] do
        assert {:invalid, _, ^session} = Session.accept(session, JSON.encode!(frame), 1)
      end
    end

    assert {:ok, :event, ^event, ^session} = Session.accept(session, JSON.encode!(event), 1)
    assert {:ok, :result, ^reply, next} = Session.accept(session, JSON.encode!(reply), 1)
    assert next.pending == %{}
  end

  test "outstanding requests have a finite limit, explicit expiry and late replies cannot complete" do
    session =
      Enum.reduce(1..Session.limit(), Session.new(@target), fn _, state ->
        {:ok, _, next} = Session.request(state, ["status"], 0)
        next
      end)

    assert map_size(session.pending) == Session.limit()
    assert {:error, :backpressure, ^session} = Session.request(session, ["status"], 1)
    {id, _} = Enum.at(session.pending, 0)
    {next, expired} = Session.expire(session, Session.timeout())
    assert length(expired) == Session.limit()
    assert next.pending == %{}

    assert {:invalid, _, ^next} =
             Session.accept(next, JSON.encode!(result(%{"id" => id})), Session.timeout())

    assert {:ok, _, _} = Session.request(next, ["status"], Session.timeout())
    {request, session} = request()

    assert {:invalid, _, ^session} =
             Session.accept(session, JSON.encode!(result(request)), Session.timeout())
  end
end
