defmodule AtlasBFFContract.RuntimeMachineTest do
  use ExUnit.Case, async: true
  alias AtlasBFFContract.Runtime.MachineProtocol, as: Wire

  test "machine diagnostics never invent or weaken a worker identity" do
    target = %{"environment" => "test", "machine" => "fixture"}
    assert {:ok, :runtime_machine_status, request} = Wire.cli(["status"], id: "r", target: target)

    assert {:ok, :runtime_machine_status, ^request} =
             Wire.decode_request_json(JSON.encode!(request))

    assert {:invalid, _} = AtlasBFFContract.Runtime.Protocol.decode_request(request)
    assert {:invalid, _} = Wire.decode_request(put_in(request, ["target", "worker"], "invented"))
    assert {:invalid, _} = Wire.cli(["start"], id: "r", target: target)
    assert {:invalid, _} = Wire.cli(["stop"], id: "r", target: target)

    assert_raise ArgumentError, fn ->
      AtlasBFFContract.Runtime.Protocol.request(:runtime_status, id: "r", target: target)
    end

    status = %{
      target: target,
      state: "unverified",
      basis: "pid_only_legacy",
      message: "ownership unknown",
      pid: 123,
      capabilities: %{
        local_status: true,
        local_start: false,
        local_stop: false,
        remote_status: false
      }
    }

    bytes =
      Wire.encode_reply(:runtime_machine_status, :result, id: "r", target: target, status: status)

    assert {:ok, :result, %{"status" => %{"target" => ^target}}} =
             Wire.decode_reply_json(:runtime_machine_status, bytes)

    assert {:ok, %{"machine" => "fixture", "json" => true}} =
             Wire.options(:runtime_machine_status_options, ["--machine", "fixture", "--json"])

    assert {:invalid, _} =
             Wire.options(:runtime_machine_status_options, [
               "--machine",
               "fixture",
               "--machine",
               "other"
             ])
  end
end
