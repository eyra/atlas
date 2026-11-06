# Historical origin regression in an isolated temporary DETS file; no app or worker.
Code.compiler_options(ignore_module_conflict: true)
Code.require_file(Path.expand("../../beam/apps/atlas_state/lib/atlas_state/links.ex", __DIR__))
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
end
