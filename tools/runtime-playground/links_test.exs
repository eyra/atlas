# Historical origin regression in an isolated temporary DETS file; no app or worker.
Code.compiler_options(ignore_module_conflict: true)
Code.require_file(Path.expand("../../beam/apps/atlas_state/lib/atlas_state/links.ex", __DIR__))
# Inject only the rebuild traversal in a separate module, never in the demo VM.
defmodule PlaygroundFoldFailure do
  def foldl(fun, acc, disk) do
    Process.put(:rebuild_disk, disk)
    visited = Process.get(:rebuild_visited)

    if visited == 1 do
      [entry] = :dets.lookup(disk, :dets.first(disk))
      :ok = fun.(entry, acc)
    end

    Process.put(:rebuild_actual_visited, visited)
    {:error, :injected_read_failure}
  end
end

Path.expand("../../beam/apps/atlas_state/lib/atlas_state/links.ex", __DIR__)
|> File.read!()
|> String.replace("defmodule AtlasState.Links do", "defmodule PlaygroundFailedLinks do")
|> String.replace(":dets.foldl(", "PlaygroundFoldFailure.foldl(")
|> Code.compile_string()

ExUnit.start(seed: 0)

defmodule PlaygroundOriginsTest do
  use ExUnit.Case
  alias AtlasState.Links
  @moduletag :tmp_dir

  test "retained historical origins use exact lookups, never a full table match", %{tmp_dir: dir} do
    file = Path.join(dir, "links.dets") |> String.to_charlist()
    {:ok, disk} = :dets.open_file(make_ref(), file: file, type: :set)

    entries =
      for n <- 1..491,
          do: {{"turn", "t#{n}", "turn_by"}, [%{"keys" => ["breaker"], "position" => n}]}

    :ok = :dets.insert(disk, entries)
    :ok = :dets.close(disk)
    table = Links.open(dir)

    try do
      :erlang.trace_pattern({:dets, :match, 2}, true, [:call_count])

      for n <- 1..491 do
        assert Links.origins(table, "turn", "t#{n}", %{"turn_by" => ["breaker"]}) ==
                 %{"turn_by" => %{"keys" => ["breaker"], "position" => n}}
      end

      assert {:call_count, 0} == :erlang.trace_info({:dets, :match, 2}, :call_count)
    after
      :erlang.trace_pattern({:dets, :match, 2}, false, [:call_count])
      Links.close(table)
    end
  end

  test "appends, removed associations, reopening, mismatches and deletion keep their meaning", %{
    tmp_dir: dir
  } do
    table = Links.open(dir)
    Links.record(table, "assignment", "a", "owner", ["breaker"], %{"position" => 1})
    Links.record(table, "assignment", "a", "owner", [], %{"position" => 2})
    assert length(Links.history(table, "assignment", "a", "owner")) == 2

    assert Links.origins(table, "assignment", "a", %{}) == %{
             "owner" => %{"keys" => [], "position" => 2}
           }

    assert Links.origins(table, "assignment", "a", %{"owner" => ["someone-else"]}) == %{}
    Links.close(table)
    table = Links.open(dir)

    try do
      assert Links.all(table, "assignment", "a")["owner"] |> length() == 2
      assert Links.origins(table, "assignment", "a", %{})["owner"]["position"] == 2
      Links.forget(table, "assignment", "a")
      assert Links.all(table, "assignment", "a") == %{}
      assert Links.history(table, "assignment", "a", "owner") == []
      Links.record(table, "assignment", "a", "owner", ["new"], %{"position" => 3})
      assert length(Links.all(table, "assignment", "a")["owner"]) == 1
    after
      Links.close(table)
    end
  end

  defp owned_indexes do
    Enum.filter(:ets.all(), &(:ets.info(&1, :owner) == self())) |> MapSet.new()
  end

  for visited <- [0, 1] do
    test "rebuild failure after #{visited} visited relations fails closed and releases resources",
         %{tmp_dir: dir} do
      visited = unquote(visited)
      table = Links.open(dir)
      Links.record(table, "kind", "a", "r1", ["x"], %{"position" => 1})
      Links.record(table, "kind", "a", "r2", [], %{"position" => 2})
      Links.record(table, "other", "a", "r1", ["y"], %{"position" => 3})
      Links.close(table)
      before = owned_indexes()
      Process.put(:rebuild_visited, visited)

      result =
        try do
          {:returned, PlaygroundFailedLinks.open(dir)}
        rescue
          error -> {:raised, error}
        end

      disk = Process.get(:rebuild_disk)

      try do
        assert {:raised, %MatchError{term: {:error, :injected_read_failure}}} = result
        assert Process.get(:rebuild_actual_visited) == visited
        assert :dets.info(disk) == :undefined
        assert owned_indexes() == before
      after
        # Red runs must also release their synthetic resources after demonstrating the leak.
        if :dets.info(disk) != :undefined, do: :dets.close(disk)
        for index <- MapSet.difference(owned_indexes(), before), do: :ets.delete(index)
      end

      table = Links.open(dir)
      assert Map.keys(Links.all(table, "kind", "a")) |> Enum.sort() == ["r1", "r2"]
      assert Links.origins(table, "kind", "a", %{"r1" => ["x"]})["r2"]["position"] == 2
      :ok = Links.forget(table, "kind", "a")
      :ok = Links.close(table)
      table = Links.open(dir)

      try do
        assert Links.all(table, "kind", "a") == %{}
        assert Links.history(table, "kind", "a", "r1") == []
        assert Links.history(table, "kind", "a", "r2") == []
        assert map_size(Links.all(table, "other", "a")) == 1
      after
        Links.close(table)
      end
    end
  end

  test "owner death after synced append rebuilds all relations on reopen", %{tmp_dir: dir} do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        table = Links.open(dir)
        Links.record(table, "kind", "a", "r1", ["b", "z"], %{"position" => 1})
        :ok = :dets.insert(table.disk, {{"kind", "a", "r2"}, [%{"keys" => [], "position" => 2}]})
        :ok = :dets.sync(table.disk)
        send(parent, {:ready, table.index})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:ready, index}, 1000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1000
    assert :ets.info(index) == :undefined
    table = Links.open(dir)

    try do
      assert map_size(Links.all(table, "kind", "a")) == 2
      assert map_size(Links.origins(table, "kind", "a", %{"r1" => ["z", "b"]})) == 2
      Links.forget(table, "kind", "a")
      assert Links.history(table, "kind", "a", "r2") == []
    after
      Links.close(table)
    end
  end
end
