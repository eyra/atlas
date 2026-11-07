defmodule AtlasRuntime.ExecutionEvents do
  @moduledoc "Bounded, durable execution snapshots; completion does not imply task verification."

  @retention 256
  @max_bytes 4 * 1024 * 1024
  @max_sequence 9_223_372_036_854_775_807
  @filename "execution-events.json"

  def open(dir) do
    path = Path.join(dir, @filename)

    case File.stat(path) do
      {:error, :enoent} ->
        store = %{
          "version" => 1,
          "epoch" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          "recording_started_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "sequence" => 0,
          "events" => []
        }

        persist(dir, store)

      {:ok, %{size: size}} when size <= @max_bytes ->
        case JSON.decode(File.read!(path)) do
          {:ok, store} -> validate!(store)
          {:error, _} -> invalid_store!()
        end

      {:ok, _} ->
        invalid_store!()

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read execution event journal", path: path
    end
  end

  def append(dir, store, run) do
    kind =
      case run.state do
        "running" -> "execution_accepted"
        "finished" -> "execution_finished"
        "failed" -> "execution_failed"
        "stopped" -> "execution_stopped"
        _ -> raise ArgumentError, "unsupported execution event state"
      end

    event = %{
      "sequence" => store["sequence"] + 1,
      "kind" => kind,
      "turn_id" => run.id,
      "backend" => run.backend,
      "session_id" => Map.get(run, :session_id),
      "model" => Map.get(run, :model),
      "timestamp" => if(kind == "execution_accepted", do: run.started_at, else: run.ended_at)
    }

    event =
      if kind == "execution_accepted" do
        operation = if get_in(run, [:selection, "reason"]) == "continuation", do: "continue", else: "start"
        Map.put(event, "operation", operation)
      else
        event
      end

    unless valid_event?(event), do: raise(ArgumentError, "invalid execution event snapshot")

    store
    |> Map.put("sequence", event["sequence"])
    |> Map.put("events", Enum.take(store["events"] ++ [event], -@retention))
    |> then(&persist(dir, &1))
  end

  def query(store, cursor, limit) do
    unless is_integer(limit) and limit in 1..100,
      do: raise(ArgumentError, "execution event limit must be an integer between 1 and 100")

    earliest = store["sequence"] - length(store["events"])
    sequence = if is_nil(cursor), do: earliest, else: parse_cursor!(store, cursor, earliest)
    remaining = Enum.drop_while(store["events"], &(&1["sequence"] <= sequence))
    events = Enum.take(remaining, limit)

    next_cursor =
      case List.last(events) do
        nil -> cursor || cursor(store, earliest)
        event -> cursor(store, event["sequence"])
      end

    %{
      "events" => events,
      "next_cursor" => next_cursor,
      "has_more" => length(remaining) > limit,
      "earliest_cursor" => cursor(store, earliest),
      "retention_gap" => is_nil(cursor) and earliest > 0,
      "recording_started_at" => store["recording_started_at"]
    }
  end

  defp parse_cursor!(store, value, earliest) do
    parsed =
      if is_binary(value) and byte_size(value) <= 52 do
        Regex.run(~r/\A([0-9a-f]{32}):(0|[1-9][0-9]{0,18})\z/, value, capture: :all_but_first)
      end

    case parsed do
      [epoch, number] ->
        sequence = String.to_integer(number)

        cond do
          epoch != store["epoch"] ->
            raise ArgumentError, "execution event cursor belongs to a different stream"

          sequence > store["sequence"] ->
            raise ArgumentError, "execution event cursor is in the future"

          sequence < earliest ->
            raise ArgumentError, "stale execution event cursor; earliest usable cursor: #{cursor(store, earliest)}"

          true ->
            sequence
        end

      _ ->
        raise ArgumentError, "malformed execution event cursor"
    end
  end

  defp cursor(store, sequence), do: store["epoch"] <> ":" <> Integer.to_string(sequence)

  defp persist(dir, store) do
    encoded = JSON.encode!(store)
    if byte_size(encoded) > @max_bytes, do: invalid_store!()
    File.mkdir_p!(dir)
    path = Path.join(dir, @filename)
    File.write!(path <> ".tmp", encoded)
    File.rename!(path <> ".tmp", path)
    store
  end

  defp validate!(%{
         "version" => 1,
         "epoch" => epoch,
         "recording_started_at" => started_at,
         "sequence" => sequence,
         "events" => events
       } = store) do
    valid =
      map_size(store) == 5 and is_binary(epoch) and
        Regex.match?(~r/\A[0-9a-f]{32}\z/, epoch) and timestamp?(started_at) and
        is_integer(sequence) and sequence >= 0 and sequence <= @max_sequence and
        is_list(events) and length(events) == min(sequence, @retention)

    unless valid, do: invalid_store!()

    events
    |> Enum.with_index(sequence - length(events) + 1)
    |> Enum.each(fn {event, expected} ->
      unless valid_event?(event) and event["sequence"] == expected, do: invalid_store!()
    end)

    store
  end

  defp validate!(_), do: invalid_store!()

  defp valid_event?(%{
         "sequence" => sequence,
         "kind" => kind,
         "turn_id" => turn,
         "backend" => backend,
         "session_id" => session,
         "model" => model,
         "timestamp" => timestamp
       } = event) do
    shape =
      case kind do
        "execution_accepted" ->
          map_size(event) == 8 and event["operation"] in ["start", "continue"]

        terminal when terminal in ["execution_finished", "execution_failed", "execution_stopped"] ->
          map_size(event) == 7

        _ ->
          false
      end

    shape and is_integer(sequence) and sequence > 0 and sequence <= @max_sequence and
      text?(turn, 128) and text?(backend, 64) and nullable_text?(session, 1024) and
      nullable_text?(model, 256) and timestamp?(timestamp)
  end

  defp valid_event?(_), do: false
  defp nullable_text?(nil, _), do: true
  defp nullable_text?(value, max), do: text?(value, max)
  defp text?(value, max), do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp timestamp?(value) do
    text?(value, 64) and match?({:ok, _, _}, DateTime.from_iso8601(value))
  end

  defp invalid_store!, do: raise(ArgumentError, "invalid or oversized execution event journal")
end
