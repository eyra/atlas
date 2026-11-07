defmodule AtlasRuntime.ExecutionEventsTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.ExecutionEvents

  @started "2026-11-07T10:00:00Z"
  @ended "2026-11-07T10:01:00Z"

  setup %{tmp_dir: dir} do
    %{dir: dir, path: Path.join(dir, "execution-events.json")}
  end

  @moduletag :tmp_dir

  defp run(id, state \\ "running") do
    %{
      id: "turn-#{id}",
      backend: "codex",
      model: nil,
      session_id: nil,
      state: state,
      started_at: @started,
      ended_at: @ended,
      selection: %{"reason" => "default"},
      assignment: "private assignment",
      result: "private output",
      error: "private error",
      folder: "/private/artifacts"
    }
  end

  defp cursor_at(reply, sequence) do
    [epoch, _] = String.split(reply["earliest_cursor"], ":")
    epoch <> ":" <> Integer.to_string(sequence)
  end

  test "opening creates a persistent empty checkpoint without historical synthesis", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "turns/old-turn"))
    File.write!(Path.join(dir, "turns/old-turn/turn.json"), JSON.encode!(run("old", "finished")))
    store = ExecutionEvents.open(dir)
    reply = ExecutionEvents.query(store, nil, 50)

    assert reply["events"] == []
    assert reply["next_cursor"] == reply["earliest_cursor"]
    assert reply["next_cursor"] =~ ~r/\A[0-9a-f]{32}:0\z/
    assert {:ok, _, _} = DateTime.from_iso8601(reply["recording_started_at"])
    refute reply["has_more"]
    refute reply["retention_gap"]
    assert ExecutionEvents.query(ExecutionEvents.open(dir), nil, 50) == reply
    assert ExecutionEvents.query(store, reply["next_cursor"], 50) == reply
  end

  test "snapshots preserve acceptance, terminal kinds and native identity across reopening", %{dir: dir} do
    first = run(1)
    finished = %{first | state: "finished", model: "native-model", session_id: "native-session"}
    continuation = %{run(2) | selection: %{"reason" => "continuation"}, session_id: "native-session"}

    store =
      Enum.reduce([first, finished, continuation, run(2, "failed"), run(3, "stopped")],
        ExecutionEvents.open(dir),
        fn snapshot, store -> ExecutionEvents.append(dir, store, snapshot) end
      )

    reply = ExecutionEvents.query(store, nil, 100)
    assert ExecutionEvents.query(ExecutionEvents.open(dir), nil, 100) == reply
    assert Enum.map(reply["events"], & &1["sequence"]) == [1, 2, 3, 4, 5]
    assert Enum.map(reply["events"], & &1["kind"]) == [
             "execution_accepted",
             "execution_finished",
             "execution_accepted",
             "execution_failed",
             "execution_stopped"
           ]

    [accepted, completed, continued, failed, stopped] = reply["events"]

    assert accepted == %{
             "sequence" => 1,
             "kind" => "execution_accepted",
             "turn_id" => "turn-1",
             "backend" => "codex",
             "model" => nil,
             "session_id" => nil,
             "timestamp" => @started,
             "operation" => "start"
           }

    assert completed == %{
             "sequence" => 2,
             "kind" => "execution_finished",
             "turn_id" => "turn-1",
             "backend" => "codex",
             "model" => "native-model",
             "session_id" => "native-session",
             "timestamp" => @ended
           }

    assert continued["operation"] == "continue"
    assert continued["timestamp"] == @started
    assert continued["session_id"] == "native-session"
    assert failed["timestamp"] == @ended
    assert stopped["timestamp"] == @ended

    for event <- reply["events"], field <- ["assignment", "result", "error", "folder", "verified"] do
      refute Map.has_key?(event, field)
    end
  end

  test "pages replay stable prefixes, extend short pages and never skip unreturned events", %{dir: dir} do
    store = ExecutionEvents.open(dir)
    checkpoint = ExecutionEvents.query(store, nil, 1)["next_cursor"]
    store = Enum.reduce(1..3, store, fn id, store -> ExecutionEvents.append(dir, store, run(id)) end)
    first = ExecutionEvents.query(store, checkpoint, 2)

    assert Enum.map(first["events"], & &1["sequence"]) == [1, 2]
    assert first["next_cursor"] == cursor_at(first, 2)
    assert first["has_more"]
    assert ExecutionEvents.query(store, checkpoint, 2) == first

    second = ExecutionEvents.query(store, first["next_cursor"], 2)
    assert Enum.map(second["events"], & &1["sequence"]) == [3]
    refute second["has_more"]

    empty = ExecutionEvents.query(store, second["next_cursor"], 2)
    assert empty["events"] == []
    assert empty["next_cursor"] == second["next_cursor"]
    refute empty["has_more"]

    store = ExecutionEvents.append(dir, store, run(4))
    assert ExecutionEvents.query(store, checkpoint, 2) == first
    extended = ExecutionEvents.query(store, first["next_cursor"], 2)
    assert Enum.map(extended["events"], & &1["sequence"]) == [3, 4]
    assert hd(extended["events"]) == hd(second["events"])
    assert extended["next_cursor"] == cursor_at(first, 4)
    refute extended["has_more"]
    assert ExecutionEvents.query(store, second["next_cursor"], 2)["events"] == [List.last(extended["events"])]
  end

  test "query rejects invalid limits and malformed, foreign or future cursors", %{dir: dir} do
    store = ExecutionEvents.open(dir)
    empty = ExecutionEvents.query(store, nil, 100)
    [epoch, _] = String.split(empty["earliest_cursor"], ":")

    for limit <- [0, -1, 101, 1.0, "1", nil, true] do
      assert_raise ArgumentError, ~r/limit.*between 1 and 100/, fn ->
        ExecutionEvents.query(store, nil, limit)
      end
    end

    for cursor <- ["", "garbage", "epoch:0", epoch <> ":-1", epoch <> ":01",
                   epoch <> ":+1", epoch <> ":0:1", epoch <> ":" <> String.duplicate("9", 100), 0, %{}] do
      assert_raise ArgumentError, ~r/malformed.*cursor/, fn ->
        ExecutionEvents.query(store, cursor, 1)
      end
    end

    foreign = ExecutionEvents.open(Path.join(dir, "foreign"))
    foreign_cursor = ExecutionEvents.query(foreign, nil, 1)["next_cursor"]

    assert_raise ArgumentError, ~r/different stream/, fn ->
      ExecutionEvents.query(store, foreign_cursor, 1)
    end

    assert_raise ArgumentError, ~r/future/, fn ->
      ExecutionEvents.query(store, cursor_at(empty, 1), 1)
    end
  end

  test "retention keeps 256 events, reports gaps and rejects stale checkpoints", %{dir: dir, path: path} do
    initial = ExecutionEvents.open(dir)
    checkpoint = ExecutionEvents.query(initial, nil, 1)["next_cursor"]
    store = Enum.reduce(1..260, initial, fn id, store -> ExecutionEvents.append(dir, store, run(id)) end)
    first = ExecutionEvents.query(store, nil, 100)

    assert first["retention_gap"]
    assert first["has_more"]
    assert first["earliest_cursor"] == cursor_at(first, 4)
    assert Enum.map(first["events"], & &1["sequence"]) == Enum.to_list(5..104)
    assert first["next_cursor"] == cursor_at(first, 104)
    assert ExecutionEvents.query(ExecutionEvents.open(dir), nil, 100) == first

    explicit = ExecutionEvents.query(store, first["earliest_cursor"], 100)
    assert explicit["events"] == first["events"]
    refute explicit["retention_gap"]

    second = ExecutionEvents.query(store, first["next_cursor"], 100)
    third = ExecutionEvents.query(store, second["next_cursor"], 100)
    assert Enum.map(first["events"] ++ second["events"] ++ third["events"], & &1["sequence"]) == Enum.to_list(5..260)
    refute third["has_more"]
    assert third["next_cursor"] == cursor_at(first, 260)
    assert File.stat!(path).size < 4 * 1024 * 1024

    for stale <- [checkpoint, cursor_at(first, 3)] do
      error = assert_raise ArgumentError, fn -> ExecutionEvents.query(store, stale, 100) end
      assert error.message == "stale execution event cursor; earliest usable cursor: #{first["earliest_cursor"]}"
    end
  end

  test "corrupt or oversized journals fail closed without changing persisted bytes", %{dir: dir, path: path} do
    store = ExecutionEvents.append(dir, ExecutionEvents.open(dir), run(1))
    [event] = store["events"]

    corrupt = [
      "not JSON",
      "null",
      JSON.encode!(Map.put(store, "version", 2)),
      JSON.encode!(Map.put(store, "epoch", "bad")),
      JSON.encode!(Map.put(store, "recording_started_at", "yesterday")),
      JSON.encode!(Map.put(store, "sequence", -1)),
      JSON.encode!(Map.put(store, "events", [])),
      JSON.encode!(Map.put(store, "events", [%{event | "sequence" => 2}])),
      JSON.encode!(Map.put(store, "events", [%{event | "kind" => "task_verified"}])),
      JSON.encode!(Map.put(store, "events", [%{event | "operation" => "retry"}])),
      JSON.encode!(Map.put(store, "events", [Map.put(event, "result", "private")])),
      JSON.encode!(Map.put(store, "events", [%{event | "model" => String.duplicate("x", 257)}])),
      JSON.encode!(Map.put(store, "unexpected", true)),
      String.duplicate(" ", 4 * 1024 * 1024 + 1)
    ]

    for bytes <- corrupt do
      File.write!(path, bytes)
      assert_raise ArgumentError, ~r/execution event journal/, fn -> ExecutionEvents.open(dir) end
      assert File.read!(path) == bytes
    end
  end

  test "maximum escaped identity fields keep a full page below the socket response cap", %{dir: dir} do
    largest = %{run(1) | id: String.duplicate("\u0000", 128),
      backend: String.duplicate("\u0000", 64), model: String.duplicate("\u0000", 256),
      session_id: String.duplicate("\u0000", 1024)}
    store = Enum.reduce(1..100, ExecutionEvents.open(dir), fn _, store ->
      ExecutionEvents.append(dir, store, largest)
    end)
    response = ExecutionEvents.query(store, nil, 100)
    assert length(response["events"]) == 100
    assert byte_size(JSON.encode!(response)) + 1 < 1_048_576
  end

  test "invalid snapshots cannot change the journal", %{dir: dir, path: path} do
    store = ExecutionEvents.open(dir)
    bytes = File.read!(path)

    for snapshot <- [
          %{run(1) | id: String.duplicate("x", 129)},
          %{run(1) | backend: String.duplicate("x", 65)},
          %{run(1) | model: String.duplicate("x", 257)},
          %{run(1) | session_id: String.duplicate("x", 1025)},
          %{run(1) | started_at: "not a timestamp"},
          %{run(1) | state: "idle"}
        ] do
      assert_raise ArgumentError, fn -> ExecutionEvents.append(dir, store, snapshot) end
      assert File.read!(path) == bytes
    end
  end
end
