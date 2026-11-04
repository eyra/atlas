# UC-Atlas-07, IS-Atlas-15: Runtime runs an agent's turns. A fact owned by an agent this
# machine runs gets a turn; the turn keeps its lease while the agent shows activity, and
# ends when it goes silent, crashes, or no longer owns the fact; the owner then gets a new
# turn. Every step is a fact in State with its cause. The agent is the stand-in (stub),
# whose mode the scenario sets in its file: no real agent runs.
import AtlasE2E.Scenario

# A turn's field as `atlas get` shows it, once it has a value for which `ok?` holds (Runtime
# looks every second).
field = fn i, key, label, ok? ->
  Enum.reduce_while(1..60, nil, fn _, last ->
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

scenario "UC-Atlas-07: Runtime runs an agent's turns, and keeps their leases", fn %{
                                                                                    t1: t1,
                                                                                    instance: i
                                                                                  } ->
  mode = fn what -> File.write!(Path.join(i.settings["runtime"]["stub_dir"], "runner"), what) end

  step "A use case runner owns gets a turn, its lease kept while runner is active", fn ->
    mode.("active")
    atlas_json(i, ["put", "agent", "--name", "Runner"])
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene with a turn"])

    {use_case, _} =
      atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "A use case for runner"])

    atlas_json(i, ["set", use_case["key"], "assigned_to=runner", "--cause", "runner builds it"])
    turn = "TU-AS-#{use_case["key"]}-1"
    Process.put(:uc07, %{scene: scene["key"], use_case: use_case["key"]})

    field.(i, turn, "State", &(&1 == "Running"))
    field.(i, turn, "Machine", &(&1 == "e2e"))
    # Renewed while runner is active: each time with what it did.
    first = field.(i, turn, "Activity", &(&1 =~ ~r/^stub step \d+$/))
    field.(i, turn, "Activity", &(&1 != first and &1 =~ ~r/^stub step \d+$/))
    field.(i, turn, "Lease until", &(&1 != "—"))

    # On its Assignment's page, in the TUI: the turn, by hint.
    home(t1)
    open_row(t1, "A scene with a turn")
    open_row(t1, "A use case for runner")
    open_row(t1, "AS-#{use_case["key"]}")
    see(t1, turn)
  end

  step "Silent: the turn loses its lease and ends; runner gets a new turn", fn ->
    %{use_case: use_case} = Process.get(:uc07)
    mode.("silent")
    why = field.(i, "TU-AS-#{use_case}-1", "Why", &(&1 =~ ~r/^silent for 3 s/))
    why =~ "no activity since" || raise why
    field.(i, "TU-AS-#{use_case}-1", "State", &(&1 == "Ended"))
    mode.("active")
    field.(i, "TU-AS-#{use_case}-2", "State", &(&1 == "Running"))
  end

  step "A crash ends the turn; runner gets the next", fn ->
    %{use_case: use_case} = Process.get(:uc07)
    # Once: the stub sets itself back to active, so the next turn does not crash too.
    mode.("crash once")
    field.(i, "TU-AS-#{use_case}-2", "Why", &(&1 =~ "the agent crashed"))
    field.(i, "TU-AS-#{use_case}-3", "State", &(&1 == "Running"))
  end

  step "Moved to another owner: its turn ends, and no new one starts", fn ->
    %{use_case: use_case} = Process.get(:uc07)
    atlas_json(i, ["put", "agent", "--name", "Coordinator"])

    atlas_json(i, [
      "set",
      use_case,
      "assigned_to=coordinator",
      "--cause",
      "the coordinator takes it"
    ])

    field.(
      i,
      "TU-AS-#{use_case}-3",
      "Why",
      &(&1 == "AS-#{use_case} is no longer runner's to work on")
    )

    Process.sleep(3_000)
    {out, status, _} = atlas(i, ["get", "TU-AS-#{use_case}-4"])
    status != 0 || raise "a fourth turn started:\n#{out}"
  end

  # The scenes list stays short enough for the scenarios after this one.
  step "Clean up: delete what this scenario made", fn ->
    %{scene: scene, use_case: use_case} = Process.get(:uc07)
    home(t1)

    for key <- Enum.map(1..3, &"TU-AS-#{use_case}-#{&1}") ++ [use_case, scene],
        do: {_, 0, _} = atlas(i, ["delete", key])

    gone(t1, "A scene with a turn")
  end
end
