defmodule AtlasRuntimeTest do
  use ExUnit.Case, async: false

  alias AtlasRuntime.{Engine, FakeState}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")

    # A fresh supervisor for the turns: none is left from another test.
    :ok = Supervisor.terminate_child(AtlasRuntime.Root, AtlasRuntime.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasRuntime.Root, AtlasRuntime.Supervisor)
    eventually(fn -> Registry.count(AtlasRuntime.Turns) == 0 end)

    start_supervised!(FakeState)
    FakeState.put("clerk", %{"key" => "ada"})
    FakeState.put("clerk", %{"key" => "bob"})
    %{dir: dir}
  end

  # Ada's box: its card is hers, and its flow has a state for it.
  defp box(owner \\ "ada", step \\ "packing") do
    FakeState.put("box", %{"key" => "B-1", "links" => %{"card" => ["C-B-1"]}})

    FakeState.put("card", %{
      "key" => "C-B-1",
      "values" => %{"step" => step},
      "links" => %{"owned_by" => List.wrap(owner)}
    })
  end

  defp engine(dir, more \\ []) do
    opts =
      [
        machine: "here",
        agents: %{"ada" => %{"port" => "stub"}},
        silence: 900,
        max: 60_000,
        lease: 100,
        every: 200,
        stub_dir: dir,
        crash_pause: 50,
        leave_grace: 300,
        name: Engine
      ]
      |> Keyword.merge(more)

    start_supervised!({Engine, opts})
  end

  defp mode(dir, agent, mode), do: File.write!(Path.join(dir, agent), mode)

  defp run(key), do: FakeState.get("run", key)

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not happen")
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  test "an owned open fact gets a turn; its lease follows the agent's activity", %{dir: dir} do
    box()
    engine(dir)

    eventually(fn -> run("R-C-B-1-1") != nil end)
    turn = run("R-C-B-1-1")
    assert turn["values"]["status"] == "going"
    assert turn["values"]["host"] == "here"
    assert turn["links"] == %{"run_on" => ["C-B-1"], "run_by" => ["ada"]}

    [{"run", created} | _] = FakeState.sent()
    assert created["op"] == "create" and created["by"] == "runtime"
    assert created["cause"] == "ada owns C-B-1, and no turn of it runs: a turn (1)"

    # The stub is active: the lease is renewed, each time with what the agent did.
    eventually(fn ->
      Enum.count(FakeState.sent(), &match?({"run", %{"op" => "change"}}, &1)) >= 2
    end)

    {"run", renewed} = Enum.find(FakeState.sent(), &match?({"run", %{"op" => "change"}}, &1))
    assert renewed["cause"] =~ ~r/^activity: stub step \d+$/
    assert renewed["values"]["until"] =~ ~r/^\d{4}-\d\d-\d\dT/
    assert run("R-C-B-1-1")["values"]["status"] == "going"
  end

  test "a silent turn loses its lease and ends; the owner gets a new turn", %{dir: dir} do
    box()
    mode(dir, "ada", "silent")
    engine(dir)

    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["reason"] =~ ~r/^silent for 0 s: no activity since /
    refute Map.has_key?(run("R-C-B-1-1")["values"], "until")

    # Still ada's, and open: the next round starts another turn.
    mode(dir, "ada", "active")
    eventually(fn -> run("R-C-B-1-2")["values"]["status"] == "going" end)
  end

  test "a crashed agent ends its turn; one that ends it, too", %{dir: dir} do
    box()
    engine(dir)
    eventually(fn -> run("R-C-B-1-1") != nil end)

    mode(dir, "ada", "crash once")
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["reason"] =~ "the agent crashed: :crashed"
    eventually(fn -> run("R-C-B-1-2")["values"]["status"] == "going" end)

    mode(dir, "ada", "end")

    eventually(fn ->
      run("R-C-B-1-2")["values"]["reason"] == "the agent ended its turn: the stub ended its turn"
    end)
  end

  test "only the owner's turn runs: one that moves away ends it; nobody else gets one", %{
    dir: dir
  } do
    box()
    engine(dir)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "going" end)

    # Flow, or anyone, moves it to bob, whom this machine does not run.
    box("bob")
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["reason"] == "C-B-1 is no longer ada's to work on"
    Process.sleep(500)
    assert FakeState.all("run") |> length() == 1
  end

  test "a turn whose item left its agent may still end by itself, for the grace", %{dir: dir} do
    box()
    engine(dir, leave_grace: 5_000)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "going" end)

    # As when ada hands it on itself: the item moves, then ada ends its turn.
    box("bob")
    Process.sleep(500)
    assert run("R-C-B-1-1")["values"]["status"] == "going"
    mode(dir, "ada", "end")

    eventually(fn ->
      run("R-C-B-1-1")["values"]["reason"] ==
        "C-B-1 is no longer ada's to work on, and the agent ended its turn by itself: " <>
          "the stub ended its turn"
    end)
  end

  test "a fact Flow has no state for (done) gets no turn", %{dir: dir} do
    box("ada", nil)
    engine(dir)
    Engine.round(Engine)
    Process.sleep(300)
    assert FakeState.all("run") == []
  end

  test "a turn running in State with no process here is ended (Runtime restarted)", %{dir: dir} do
    box("bob")

    FakeState.put("run", %{
      "key" => "R-C-B-1-1",
      "values" => %{"status" => "going", "host" => "here"},
      "links" => %{"run_on" => ["C-B-1"], "run_by" => ["ada"]}
    })

    # Another machine's turn is not this one's to end.
    FakeState.put("run", %{
      "key" => "R-X-1",
      "values" => %{"status" => "going", "host" => "there"}
    })

    engine(dir)
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)

    assert run("R-C-B-1-1")["values"]["reason"] ==
             "no process runs it on here any more (Runtime restarted)"

    assert run("R-X-1")["values"]["status"] == "going"
  end

  test "an agent's turn limit: no more turns here than that", %{dir: dir} do
    box()
    mode(dir, "ada", "end")
    engine(dir, agents: %{"ada" => %{"port" => "stub", "turn_limit" => 1}})
    eventually(fn -> run("R-C-B-1-1")["values"]["status"] == "over" end)
    assert run("R-C-B-1-1")["values"]["done_at"] =~ ~r/^\d{4}-/
    Process.sleep(800)
    assert length(FakeState.all("run")) == 1
  end

  test "3 crashes in 10 minutes: no more turns here, and the agent says it cannot run", %{
    dir: dir
  } do
    box()
    mode(dir, "ada", "crash")
    engine(dir)

    eventually(fn -> run("R-C-B-1-3")["values"]["status"] == "over" end)
    eventually(fn -> FakeState.get("clerk", "ada")["values"]["stuck"] != nil end)

    assert FakeState.get("clerk", "ada")["values"]["stuck"] =~
             ~r/^on here since .*: 3 crashes in 10 minutes$/

    Process.sleep(800)
    assert run("R-C-B-1-4") == nil

    {"clerk", marked} = Enum.find(FakeState.sent(), &match?({"clerk", _}, &1))

    assert marked["by"] == "runtime" and
             marked["cause"] == "ada crashed 3 times in 10 minutes on here"
  end

  test "a machine that runs no agents does nothing", %{dir: dir} do
    box()
    engine(dir, agents: %{})
    Engine.round(Engine)
    assert FakeState.all("run") == []
  end
end
