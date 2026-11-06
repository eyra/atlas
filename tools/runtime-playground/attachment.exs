defmodule RuntimePlayground.Attachment do
  @moduledoc "Private adapter policy only. No registry grant is worker authority."
  alias AtlasBFFContract.Runtime.AttachmentProtocol, as: Wire
  @capabilities %{snapshot: true, control: false, guidance: false, output: false, replay: false}

  def select(snapshot, execution, target) do
    cond do
      execution["worker"] != target ->
        {:error, "wrong_target"}

      not Enum.all?(
        [execution["turn"], execution["attempt"]],
        &(is_binary(&1) and String.trim(&1) != "")
      ) ->
        {:error, "exact_execution_required"}

      true ->
        case Enum.find(
               snapshot["turns"],
               &(&1["execution"] == execution and &1["state"] == "running")
             ) do
          nil -> {:error, "stale_execution"}
          turn -> {:ok, turn}
        end
    end
  end

  def fields(execution, turn),
    do: %{
      target: execution["worker"],
      execution: execution,
      capabilities: @capabilities,
      turn: turn
    }

  def error(execution, code),
    do: %{
      target: execution["worker"],
      execution: execution,
      error: %{
        code: code,
        message: "private attachment refused or closed: " <> code,
        retryable: false
      }
    }

  def reply(name, request, snapshot, target) do
    execution = request["execution"]

    if request["target"] == target do
      case select(snapshot, execution, target) do
        {:ok, turn} ->
          {:ok,
           Wire.encode_reply(name, :result, Map.put(fields(execution, turn), :id, request["id"]))}

        {:error, code} ->
          {:error,
           Wire.encode_reply(name, :error, Map.put(error(execution, code), :id, request["id"]))}
      end
    else
      {:error,
       Wire.encode_reply(
         name,
         :error,
         Map.put(error(execution, "wrong_target"), :id, request["id"])
       )}
    end
  end
end
