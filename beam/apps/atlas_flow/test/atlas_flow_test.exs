defmodule AtlasFlowTest do
  use ExUnit.Case, async: false

  alias AtlasFlow.{Definition, Engine, FakeState}

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")

    # A fresh supervisor for the facts' processes: none is left from another test, and one
    # killed in an earlier test does not count against the restarts it allows.
    :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    # Registry drops a stopped process's name a moment later; till then the engine finds it.
    eventually(fn -> Registry.count(AtlasFlow.Items) == 0 end)

    start_supervised!(FakeState)
    # Who can own, as facts: the owners the definition names must exist.
    for key <- ["ada", "bob"], do: FakeState.put("clerk", %{"key" => key})
    :ok
  end

  defp engine, do: start_supervised!({Engine, every: 3_600_000})

  defp alive(key), do: Registry.lookup(AtlasFlow.Items, {"box", key}) != []

  defp eventually(fun, tries \\ 150) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not happen")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  describe "the state a fact is in" do
    @flow FakeState.flow()

    test "the first state that holds; the last when none other does" do
      name = fn fact, children ->
        {state, _} = Definition.state_of(@flow, fact, children, ["in_box"])
        state["name"]
      end

      assert name.(%{"completion" => %{"done" => true}}, []) == "done"
      assert name.(%{"progress" => %{"value" => "check"}}, []) == "check"
      assert name.(%{"progress" => %{"value" => "draft"}}, []) == "packing"
      assert name.(%{}, []) == "packing"
    end

    test "reopened: the newest fact removed the link, and nothing came under it since" do
      fact = %{
        "progress" => %{"value" => "check"},
        "origins" => %{"signed_by" => %{"keys" => [], "position" => 40, "cause" => "a crack"}}
      }

      older = %{"origins" => %{"in_box" => %{"position" => 12}}}
      newer = %{"origins" => %{"in_box" => %{"position" => 41}}}

      assert {%{"name" => "again"} = state, vars} =
               Definition.state_of(@flow, fact, [older], ["in_box"])

      assert Definition.expected(state, vars) == "Again: a crack"
      assert Definition.owner(state) == "bob"

      # A crate came under it since: the work goes on as usual.
      assert {%{"name" => "check"}, _} =
               Definition.state_of(@flow, fact, [older, newer], ["in_box"])

      signed = put_in(fact, ["origins", "signed_by"], %{"keys" => ["ada"], "position" => 40})
      assert {%{"name" => "check"}, _} = Definition.state_of(@flow, signed, [], ["in_box"])
    end

    test "done: nobody owns it and nothing is expected" do
      done = hd(@flow["states"])
      assert Definition.owner(done) == nil
      assert Definition.expected(done, %{}) == nil
      assert Definition.expected(%{"expected" => "Again: {note}"}, %{"note" => ""}) == "Again"
    end

    test "a definition State found problems in is not run" do
      assert Definition.kinds(FakeState.description()) == ["box"]
      assert Definition.kinds(FakeState.description(FakeState.flow(), ["x has no owner"])) == []
    end
  end

  describe "one process per open fact" do
    test "at boot, a process for every open fact; it writes owner and expected, with the cause" do
      FakeState.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      FakeState.put("box", %{"key" => "B-2", "completion" => %{"done" => true}})
      engine()

      eventually(fn -> FakeState.get("box", "B-1")["values"]["todo"] == "Check it" end)
      assert alive("B-1")
      refute alive("B-2")

      assert [
               %{
                 "op" => "change",
                 "key" => "B-1",
                 "values" => %{"todo" => "Check it"},
                 "links" => %{"owned_by" => ["ada"]},
                 "by" => "flow",
                 "cause" => "Flow pack: all in it is packed → ada"
               }
             ] = FakeState.sent()

      # Starting a second process for the same fact fails.
      assert {:error, {:already_started, _}} =
               DynamicSupervisor.start_child(
                 AtlasFlow.Supervisor,
                 {AtlasFlow.Item, {"box", "B-1", every: 60_000}}
               )
    end

    test "on a hint it looks again at once; once done it clears what was expected and stops" do
      FakeState.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      engine()
      eventually(fn -> FakeState.get("box", "B-1")["values"]["todo"] == "Check it" end)

      # Signed off: the fact is completed. A hint of any kind pokes it.
      FakeState.put(
        "box",
        Map.merge(FakeState.get("box", "B-1"), %{"completion" => %{"done" => true}})
      )

      FakeState.put("crate", %{"key" => "C-1", "links" => %{"in_box" => ["B-1"]}})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("crate", %{"op" => "change", "key" => "C-1", "values" => %{}})

      eventually(fn -> not alive("B-1") end)
      fact = FakeState.get("box", "B-1")
      refute Map.has_key?(fact["values"], "todo")
      assert fact["links"]["owned_by"] == []
      assert List.last(FakeState.sent())["cause"] == "Flow pack: done"
    end

    test "nothing is written when the stored owner and expected already fit (safe to repeat)" do
      FakeState.put("box", %{
        "key" => "B-1",
        "values" => %{"todo" => "Pack it"},
        "links" => %{"owned_by" => ["bob"]}
      })

      server = engine()
      :ok = Engine.round(server)
      Process.sleep(100)
      assert FakeState.sent() == []
      assert alive("B-1")
    end

    test "the hint of Flow's own write is passed over; a walk up reads plainly" do
      FakeState.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      FakeState.put("crate", %{"key" => "C-1", "links" => %{"in_box" => ["B-1"]}})
      server = engine()
      eventually(fn -> FakeState.get("box", "B-1")["values"]["todo"] == "Check it" end)
      # The write was Flow's last read or write; the engine has its hint by now.
      _ = :sys.get_state(server)
      {settled, _} = FakeState.reads()

      # Flow's own write came back as a hint: nothing read again for it, not even after a
      # poke's settle time (50 ms).
      Process.sleep(150)
      assert {^settled, _} = FakeState.reads()

      # Someone else's change to the crate walks up to the box, reading the crate plainly.
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("crate", %{"op" => "change", "key" => "C-1", "values" => %{}})

      eventually(fn -> elem(FakeState.reads(), 1) >= 2 end)
    end

    test "an owner set by hand stays while the state stays; a new state moves it" do
      FakeState.put("clerk", %{"key" => "cy"})

      FakeState.put("box", %{
        "key" => "B-1",
        "values" => %{"todo" => "Pack it"},
        "links" => %{"owned_by" => ["cy"]},
        "origins" => %{"owned_by" => %{"keys" => ["cy"], "by" => "ada", "cause" => "cy packs"}}
      })

      engine()
      Process.sleep(200)
      # Packing still: cy, whom ada chose, stays.
      assert FakeState.sent() == []

      # All in it is packed: a new state, and its owner.
      FakeState.put(
        "box",
        Map.put(FakeState.get("box", "B-1"), "progress", %{"value" => "check"})
      )

      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("box", %{"op" => "change", "key" => "B-1", "values" => %{}})

      eventually(fn -> FakeState.get("box", "B-1")["links"]["owned_by"] == ["ada"] end)
    end

    test "with a state field, the state's name is written; alone it moves no owner" do
      FakeState.set_description(
        FakeState.description(Map.put(FakeState.flow(), "state_field", "step"))
      )

      FakeState.put("clerk", %{"key" => "cy"})

      FakeState.put("box", %{
        "key" => "B-1",
        "values" => %{"todo" => "Pack it"},
        "links" => %{"owned_by" => ["cy"]},
        "origins" => %{"owned_by" => %{"keys" => ["cy"], "by" => "ada", "cause" => "cy packs"}}
      })

      engine()
      eventually(fn -> FakeState.get("box", "B-1")["values"]["step"] == "packing" end)
      # Only the name: what is expected was right, and cy, whom ada chose, stays.
      assert [%{"values" => %{"step" => "packing"}} = sent] = FakeState.sent()
      refute Map.has_key?(sent, "links")
      assert FakeState.get("box", "B-1")["links"]["owned_by"] == ["cy"]
    end

    test "an owner Flow, a migration or nobody set follows the state" do
      FakeState.put("box", %{
        "key" => "B-1",
        "values" => %{"todo" => "Pack it"},
        "links" => %{"owned_by" => ["ada"]},
        "origins" => %{"owned_by" => %{"keys" => ["ada"], "by" => "migration"}}
      })

      engine()
      eventually(fn -> FakeState.get("box", "B-1")["links"]["owned_by"] == ["bob"] end)
      assert [%{"values" => values, "links" => %{"owned_by" => ["bob"]}}] = FakeState.sent()
      assert values == %{}
    end

    test "an owner that does not exist yet: what is expected is written, the owner waits" do
      FakeState.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      GenServer.call(FakeState, {:drop, "clerk", "ada"})
      engine()
      eventually(fn -> FakeState.get("box", "B-1")["values"]["todo"] == "Check it" end)
      assert [%{"values" => %{"todo" => "Check it"}} = sent] = FakeState.sent()
      refute Map.has_key?(sent, "links")

      # Once the owner is made, the fact gets it at once.
      FakeState.put("clerk", %{"key" => "ada"})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("clerk", %{"op" => "create", "key" => "ada", "values" => %{}})

      eventually(fn -> FakeState.get("box", "B-1")["links"]["owned_by"] == ["ada"] end)
    end

    test "State does not answer whether the owner exists: nothing is written, not half" do
      FakeState.put("box", %{"key" => "B-1", "progress" => %{"value" => "check"}})
      GenServer.call(FakeState, {:busy, "clerk", "ada"})
      engine()
      eventually(fn -> elem(FakeState.reads(), 1) >= 1 and alive("B-1") end)
      Process.sleep(200)
      assert FakeState.sent() == []

      # State answers again: the next look writes both, in one change.
      GenServer.call(FakeState, {:free, "clerk", "ada"})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("box", %{"op" => "change", "key" => "B-1", "values" => %{}})

      eventually(fn -> FakeState.get("box", "B-1")["links"]["owned_by"] == ["ada"] end)

      assert [%{"values" => %{"todo" => "Check it"}, "links" => %{"owned_by" => ["ada"]}}] =
               Enum.filter(FakeState.sent(), &(&1["by"] == "flow"))
    end

    test "a fact made later gets its process from its hint" do
      engine()
      FakeState.put("box", %{"key" => "B-7"})
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")

      {:stored, _} =
        AtlasFlow.Talk.put("box", %{"op" => "change", "key" => "B-7", "values" => %{}})

      eventually(fn -> FakeState.get("box", "B-7")["values"]["todo"] == "Pack it" end)
      assert alive("B-7")
    end

    test "a crashed process is started again and goes on from State" do
      FakeState.put("box", %{"key" => "B-1"})
      engine()
      eventually(fn -> alive("B-1") end)
      [{pid, _}] = Registry.lookup(AtlasFlow.Items, {"box", "B-1"})
      Process.exit(pid, :kill)

      eventually(fn ->
        match?([{other, _}] when other != pid, Registry.lookup(AtlasFlow.Items, {"box", "B-1"}))
      end)
    end
  end
end
