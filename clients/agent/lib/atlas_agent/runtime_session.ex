defmodule AtlasAgent.RuntimeSession do
  @moduledoc "Bounded shared client correlation and exact attachment identity; no worker lifecycle."
  alias AtlasBFFContract.Wire.Runtime.Protocol, as: Wire
  @limit 8
  @timeout 10_000
  def limit, do: @limit
  def timeout, do: @timeout
  def new(target), do: %{target: target, pending: %{}, wire: Wire, execution: nil, sequence: -1}

  def attach(execution) do
    execution = Wire.model(:runtime_execution, execution)

    unless Enum.all?(
             [execution["turn"], execution["attempt"]],
             &(is_binary(&1) and String.trim(&1) != "")
           ),
           do: raise(ArgumentError, "attachment requires a fenced turn and nonempty attempt")

    %{
      new(execution["worker"])
      | execution: execution,
        wire: AtlasBFFContract.Wire.Runtime.AttachmentProtocol
    }
  end

  def reconnect(session), do: %{session | pending: %{}, sequence: -1}

  def request(session, words, now) do
    if map_size(session.pending) >= @limit do
      {:error, :backpressure, session}
    else
      id = Integer.to_string(System.unique_integer([:positive]))

      params = %{id: id, target: session.target}

      params =
        if session.execution, do: Map.put(params, :execution, session.execution), else: params

      case session.wire.cli(words, params) do
        {:ok, name, frame} ->
          entry = %{name: name, expires: now + @timeout}
          {:ok, frame, put_in(session, [:pending, id], entry)}

        {:invalid, why} ->
          {:error, why, session}
      end
    end
  end

  def expire(session, now) do
    {expired, remaining} =
      Enum.split_with(session.pending, fn {_, entry} -> entry.expires <= now end)

    {%{session | pending: Map.new(remaining)}, Enum.map(expired, &elem(&1, 0))}
  end

  def wait(session, now) do
    Enum.reduce(session.pending, 1000, fn {_, entry}, wait ->
      min(wait, max(entry.expires - now, 0))
    end)
  end

  def accept(session, bytes, now) do
    case session.wire.decode_event_json(bytes) do
      {:ok, _, frame} ->
        if bound?(frame, session) and fresh?(frame, session),
          do:
            {:ok, :event, frame,
             if(session.execution, do: %{session | sequence: frame["sequence"]}, else: session)},
          else: {:invalid, "event target mismatch or repeated sequence", session}

      _ ->
        accept_reply(session, bytes, now)
    end
  end

  defp accept_reply(session, bytes, now) do
    with {:ok, %{"id" => id}} <- JSON.decode(bytes),
         %{name: name, expires: expires} when expires > now <- session.pending[id],
         {:ok, kind, frame} <- session.wire.decode_reply_json(name, bytes) do
      if bound?(frame, session) do
        {:ok, kind, frame, %{session | pending: Map.delete(session.pending, id)}}
      else
        {:invalid, "reply target mismatch", session}
      end
    else
      _ -> {:invalid, "malformed, expired, duplicate or unknown reply", session}
    end
  end

  defp fresh?(_, %{execution: nil}), do: true
  defp fresh?(frame, session), do: frame["sequence"] > session.sequence

  defp bound?(frame, %{execution: execution, target: target}) when not is_nil(execution) do
    frame["target"] == target and frame["execution"] == execution and
      (Map.has_key?(frame, "error") or frame["turn"]["execution"] == execution)
  end

  defp bound?(%{"op" => "error"} = frame, %{target: target}),
    do: not Map.has_key?(frame, "target") or frame["target"] == target

  defp bound?(frame, %{target: target}) do
    frame["target"] == target and frame["status"]["target"] == target and
      Enum.all?(frame["status"]["turns"], &(&1["execution"]["worker"] == target))
  end
end
