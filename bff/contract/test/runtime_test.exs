defmodule AtlasBFFContract.RuntimeTest do
  use ExUnit.Case, async: true
  alias AtlasBFFContract.Runtime.Protocol, as: Wire

  @target %{"environment" => "private", "machine" => "local", "worker" => "stub"}
  @status %{
    "target" => @target,
    "engine_running" => false,
    "capabilities" => %{
      "controls" => %{"status" => true, "start" => true, "stop" => true, "stub_mode" => true}
    },
    "turns" => []
  }

  test "every literal CLI binding produces a typed control request and round trips" do
    for %{name: name, words: words} <- Wire.commands() do
      assert {:ok, ^name, request} = Wire.cli(words, %{id: "request-1", target: @target})
      assert request["channel"] == "control"
      assert request["id"] == "request-1"
      assert request["target"] == @target
      assert {:ok, ^name, ^request} = Wire.decode_request_json(JSON.encode!(request))
      assert {:invalid, _} = Wire.decode_event(request)
    end

    assert {:invalid, _} = Wire.cli(["please stop"], %{id: "1", target: @target})
    assert {:invalid, _} = Wire.cli(["mode", "unknown"], %{id: "1", target: @target})
  end

  test "strict version, envelope, identity and capability validation fails visibly" do
    request = Wire.request(:runtime_status, %{id: "1", target: @target})

    for bad <- [
          Map.put(request, "version", "future"),
          Map.put(request, "op", "unknown"),
          Map.put(request, "prompt", "stop"),
          Map.delete(request, "id"),
          put_in(request, ["target", "worker"], 10),
          put_in(request, ["target", "extra"], "unknown")
        ] do
      assert {:invalid, _} = Wire.decode_request(bad)
    end

    assert {:invalid, _} = Wire.decode_request_json("{")
    assert {:invalid, _} = Wire.decode_request_json("[]")

    assert_raise ArgumentError, fn ->
      Wire.model(:runtime_status, put_in(@status, ["capabilities", "unknown"], true))
    end

    assert_raise ArgumentError, fn ->
      Wire.model(:runtime_status, put_in(@status, ["capabilities", "controls", "start"], "yes"))
    end
  end

  test "result and typed error preserve correlation while events use their own channel" do
    result =
      Wire.encode_reply(:runtime_start, :result, %{
        id: "start-1",
        target: @target,
        status: @status
      })

    assert {:ok, :result, %{"id" => "start-1", "status" => @status}} =
             Wire.decode_reply_json(:runtime_start, result)

    error =
      Wire.encode_reply(:runtime_stop, :error, %{
        id: "stop-1",
        target: @target,
        error: %{code: "unauthorized", message: "identity not authorized", retryable: false}
      })

    assert {:ok, :error, %{"id" => "stop-1", "error" => %{"code" => "unauthorized"}}} =
             Wire.decode_reply_json(:runtime_stop, error)

    assert {:invalid, _} = Wire.decode_reply_json(:runtime_stop, "{}")

    event =
      Wire.encode_event(:runtime_status_event, %{sequence: 1, target: @target, status: @status})

    assert {:ok, :runtime_status_event, %{"channel" => "event", "sequence" => 1}} =
             Wire.decode_event_json(event)

    assert {:invalid, _} = Wire.decode_request_json(event)
    assert {:invalid, _} = Wire.decode_reply_json(:runtime_status, event)
  end

  test "shared imported models, generated structs and unfenced execution remain honest" do
    own = AtlasBFFContract.Runtime.__schema__().models
    shared = AtlasBFFContract.Blocks.__schema__().models
    assert Enum.all?(own, fn model -> Enum.any?(shared, &(&1 == model)) end)
    assert %AtlasBFFContract.Runtime.Types.RuntimeWorker{worker: "stub"}.worker == "stub"
    execution = Wire.model(:runtime_execution, %{worker: @target, turn: "private-turn"})
    refute Map.has_key?(execution, "attempt")
    assert Wire.model(:runtime_status, @status) == @status
    refute Map.has_key?(@status["capabilities"], "harness")
  end
end
