# UC-Atlas-07, IS-Atlas-23: failure actions in the test TUI. `!` on a page opens what can
# fail there; each failure is caused after a confirm, and its recovery is seen: a killed
# agent's turn ends as a crash and a new one starts; a killed process of Flow comes back; an
# idle, silent or empty agent's turns end and new ones start; a dropped hint is made up by
# the reconcile; Control offline, and the node restarted, and both TUIs come back. Against
# the stand-in agent tester only: no real agent runs.
import AtlasE2E.Scenario

# A turn's field as `atlas get` shows it, once it has a value for which `ok?` holds.
field = fn i, key, label, ok? ->
  Enum.reduce_while(1..120, nil, fn _, last ->
    {out, status, _} = atlas(i, ["get", key, "--json"])

    value =
      with 0 <- status,
           {:ok, got} <- JSON.decode(out),
           do: Enum.find_value(got["fields"], fn [l, v] -> l == label && v end),
           else: (_ -> nil)

    if value != nil and ok?.(value),
      do: {:halt, value},
      else: Process.sleep(250) && {:cont, last}
  end) || raise "#{key}: #{label} never got there"
end

# The use case's turns, newest last, and the running one (when one runs).
turns = fn i, use_case ->
  {rows, _} = atlas_json(i, ["list", "turn"])

  rows
  |> Enum.filter(&String.starts_with?(&1["key"], "TU-AS-#{use_case}-"))
  |> Enum.sort_by(&(&1["key"] |> String.split("-") |> List.last() |> String.to_integer()))
end

state = fn i, key ->
  {got, _} = atlas_json(i, ["get", key])
  Enum.find_value(got["fields"], fn [l, v] -> l == "State" && v end)
end

running = fn i, use_case ->
  Enum.reduce_while(1..120, nil, fn _, _ ->
    case turns.(i, use_case)
         |> Enum.reverse()
         |> Enum.find(&(state.(i, &1["key"]) == "Running")) do
      nil -> Process.sleep(250) && {:cont, nil}
      turn -> {:halt, turn["key"]}
    end
  end) || raise "no turn of #{use_case} runs"
end

# `!` on the page shown, then the failure, then its confirm.
fail = fn tui, label ->
  press(tui, "!")
  see(tui, "Failures: ")
  open_row(tui, label)
  see(tui, "#{label}?")
  press(tui, "y")
end

scenario "UC-Atlas-07: failure actions in the test TUI, each seen as it recovers", fn %{
                                                                                        t1: t1,
                                                                                        t2: t2,
                                                                                        instance:
                                                                                          i
                                                                                      } ->
  mode = fn what -> File.write!(Path.join(i.settings["runtime"]["stub_dir"], "tester"), what) end

  step "A use case tester owns gets a turn", fn ->
    mode.("active")
    atlas_json(i, ["put", "agent", "--name", "Tester"])
    atlas_json(i, ["put", "agent", "--name", "Onlooker"])
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene that fails"])

    {use_case, _} =
      atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "A use case for tester"])

    atlas_json(i, ["set", use_case["key"], "assigned_to=tester", "--cause", "tester builds it"])
    Process.put(:fails, %{scene: scene["key"], use_case: use_case["key"]})
    field.(i, "TU-AS-#{use_case["key"]}-1", "State", &(&1 == "Running"))
  end

  step "! on a turn: kill its agent; the turn ends as a crash, and a new one starts", fn ->
    %{use_case: use_case} = Process.get(:fails)
    turn = running.(i, use_case)
    home(t1)
    open_row(t1, "A scene that fails")
    open_row(t1, "A use case for tester")
    open_row(t1, "AS-#{use_case}")
    see(t1, "Assignment AS-#{use_case}")
    open_row(t1, turn)
    see(t1, "Turn #{turn}")
    fail.(t1, "Kill its agent")
    see(t1, "Killed tester's process for #{turn}")
    field.(i, turn, "Why", &(&1 =~ "the agent crashed: :killed"))
    # After the crash pause (10 s), tester's next turn.
    running.(i, use_case) != turn || raise "no new turn after #{turn}"
  end

  step "! on the use case: kill Flow's process for it; it comes back", fn ->
    %{use_case: use_case} = Process.get(:fails)
    home(t1)
    open_row(t1, "A scene that fails")
    open_row(t1, "A use case for tester")
    see(t1, "Use case #{use_case}: A use case for tester")
    fail.(t1, "Kill its process")
    see(t1, ~r/Killed Flow's process for #{use_case}; back as a new one/)
    see(t1, "Use case #{use_case}")
  end

  step "! on tester: idle, silent, then empty; each time its turn ends and a new one starts",
       fn ->
         %{use_case: use_case} = Process.get(:fails)
         home(t1)
         press(t1, "g")
         open_row(t1, "Tester")
         see(t1, "Agent tester")

         # Idle: it shows it is there, and its turn runs to its maximum (15 s here).
         fail.(t1, "Make it idle")
         see(t1, "tester is idle now.")
         turn = running.(i, use_case)
         field.(i, turn, "Activity", &(&1 == "idle"))
         field.(i, turn, "Why", &(&1 =~ "longer than the maximum of 15 s"))

         # Silent: its next turn ends at the silence limit (3 s).
         fail.(t1, "Make it silent")
         see(t1, "tester is silent now.")
         turn = running.(i, use_case)
         field.(i, turn, "Why", &(&1 =~ ~r/^silent for 3 s/))

         # Empty: each turn ends at once, without a change, and the next one starts.
         fail.(t1, "Make it end its turns empty")
         see(t1, "tester ends its turns empty now.")
         Process.sleep(3_000)
         newest = List.last(turns.(i, use_case))["key"]
         field.(i, newest, "Why", &(&1 == "the agent ended its turn: the stub ended its turn"))

         fail.(t1, "Put it back to work")
         see(t1, "tester is back at work now.")
         turn = running.(i, use_case)
         field.(i, turn, "Activity", &(&1 =~ ~r/^stub step \d+$/))
       end

  step "! on the start page: drop the next hint; TUI 2 sees the change at its reconcile", fn ->
    %{use_case: use_case} = Process.get(:fails)
    # Nothing else is stored meanwhile: tester has no turn running.
    atlas_json(i, ["set", use_case, "assigned_to=onlooker", "--cause", "the onlooker holds it"])
    Process.sleep(6_000)
    home(t2)
    open_row(t2, "A scene that fails")
    see(t2, "A use case for tester")

    home(t1)
    fail.(t1, "Drop the next hint")
    see(t1, "The Bus drops the next hint")

    atlas_json(i, ["set", use_case, "title=A use case seen late"])
    see(t2, "A use case seen late", 7_000)
    see(t2, " · reconciled at ")
  end

  step "! on the start page: take Control offline; both TUIs come back by themselves", fn ->
    home(t1)
    fail.(t1, "Take Control offline for 10 s")
    see(t1, "Not connected to Control. Retrying…", 5_000)
    see(t2, "Not connected to Control. Retrying…", 5_000)
    see(t1, "● connected", 20_000)
    see(t2, "● connected", 20_000)
  end

  step "! on the start page: restart the node; the TUIs come back, and so does tester's turn",
       fn ->
         %{use_case: use_case} = Process.get(:fails)
         atlas_json(i, ["set", use_case, "assigned_to=tester", "--cause", "back to tester"])
         turn = running.(i, use_case)

         home(t1)
         fail.(t1, "Restart the node")
         see(t1, "Not connected to Control. Retrying…", 10_000)
         see(t1, "● connected", 90_000)
         see(t2, "● connected", 30_000)

         field.(i, turn, "Why", &(&1 =~ "(Runtime restarted)"))
         running.(i, use_case) != turn || raise "no new turn after #{turn}"
       end

  # The scenes list stays short enough for the scenarios after this one.
  step "Clean up: delete what this scenario made", fn ->
    %{scene: scene, use_case: use_case} = Process.get(:fails)
    atlas_json(i, ["set", use_case, "assigned_to=onlooker", "--cause", "done failing"])
    Process.sleep(6_000)
    home(t1)

    for turn <- turns.(i, use_case), do: {_, 0, _} = atlas(i, ["delete", turn["key"]])
    for key <- [use_case, scene], do: {_, 0, _} = atlas(i, ["delete", key])
    gone(t1, "A scene that fails")
  end
end
