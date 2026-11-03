# UC-Atlas-06: hand a scene to an agent. IS-Atlas-17: the agents are one key away from
# the start page (`g Agents`), each with what is assigned to it, counted from the
# Assignments that point at it.
import AtlasE2E.Scenario

# The facts of `key` once Flow has given it what is expected (its first look).
expected = fn i, key ->
  Enum.reduce_while(1..50, nil, fn _, _ ->
    {got, _} = atlas_json(i, ["get", key])

    if Enum.any?(got["fields"], &match?(["Expected", v] when v not in [nil, "", "—"], &1)),
      do: {:halt, got},
      else: Process.sleep(100) && {:cont, got}
  end)
end

scenario "UC-Atlas-06: Hand a scene to an agent", fn %{t1: t1, t2: t2, instance: i} ->
  step "g on the start page opens the agents, each with what is assigned to it", fn ->
    {agent, _} = atlas_json(i, ["put", "agent", "--name", "Ada"])
    agent["key"] == "ada" || raise inspect(agent)

    for t <- [t1, t2] do
      home(t)
      see(t, "g Agents")
      press(t, "g")
      see(t, ~r/Atlas · test\s+Agents$/m)
      see(t, ~r/ada\s+Ada\s+0 assigned/)
    end
  end

  step "A scene assigned to Ada: her row counts it, by hint in both TUIs", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene for Ada"])
    key = scene["key"]
    Process.put(:uc06, key)
    expected.(i, key)

    {got, at} = atlas_json(i, ["set", key, "assigned_to=ada", "--cause", "handed to Ada"])
    ["Assigned to", "ada"] in got["fields"] || raise inspect(got["fields"])

    for t <- [t1, t2], do: by_hint(t, ~r/ada\s+Ada\s+1 assigned/, at)
  end

  step "enter on her row opens Ada, with the scene's Assignment", fn ->
    key = Process.get(:uc06)
    open_row(t1, "Ada")
    see(t1, "Agent ada: Ada")
    see(t1, ~r/AS-#{key}\s+#{key}/)
  end

  # IS-Atlas-14: an optional deadline on the Assignment; late is worked out on read.
  step "A deadline that has passed: the Assignment is late, on its page and in Ada's list", fn ->
    key = Process.get(:uc06)

    {got, at} =
      atlas_json(i, ["set", "AS-#{key}", "deadline=2020-01-02 12:00", "--cause", "due then"])

    got["values"]["deadline"] == "2020-01-02T12:00:00Z" || raise inspect(got["values"])
    by_hint(t1, ~r/AS-#{key}\s+#{key}\s+Late · deadline 2020-01-02 12:00/, at)

    {text, 0, _} = atlas(i, ["get", key])
    text =~ "Deadline: 2020-01-02 12:00 UTC · late" || raise text
  end

  step "A deadline still to come is not late; one that is no time is refused", fn ->
    key = Process.get(:uc06)
    {_, at} = atlas_json(i, ["set", "AS-#{key}", "deadline=2099-01-02T12:00:00Z"])
    by_hint(t1, ~r/AS-#{key}\s+#{key}\s+Deadline 2099-01-02 12:00/, at)
    refute_see(t1, "Late ·")

    {%{"refused" => [why | _]}, _} =
      atlas_json(i, ["set", "AS-#{key}", "deadline=tomorrow"], 1)

    why =~ "deadline" || raise why
  end

  step "u on the Assignment changes its deadline by hand; nothing else is offered", fn ->
    key = Process.get(:uc06)
    open_row(t1, "AS-#{key}")
    see(t1, "Assignment AS-#{key}: #{key}")
    screen = see(t1, "u Update")
    screen =~ "d Delete" && raise "an Assignment goes with its fact: #{screen}"
    press(t1, "u")
    see(t1, "Update AS-#{key}")
    see(t1, "Deadline")
    press(t1, "Escape")
  end

  # IS-Atlas-83: Hand to…, the owner and a deadline in one change, on any assignable fact.
  step "h on a new scene: Hand to… Ada with a deadline, in one change; Flow keeps her", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene handed over at once"])
    key = scene["key"]
    home(t1)
    open_row(t1, "A scene handed over at once")
    see(t1, "h Hand to…")
    press(t1, "h")
    see(t1, "Hand to… #{key}")

    # To: the choice wraps; move on until it is Ada.
    Enum.reduce_while(1..10, nil, fn _, _ ->
      if settled(t1) =~ "‹ ada ›",
        do: {:halt, nil},
        else: press(t1, "Right") && {:cont, nil}
    end)

    see(t1, "‹ ada ›")
    press(t1, "Down")
    type(t1, "2099-03-04 09:30")
    at = press(t1, "C-s")
    stored(t1, "Assignment AS-#{key}", at)

    {got, _} = atlas_json(i, ["get", "AS-#{key}"])
    got["values"]["deadline"] == "2099-03-04T09:30:00Z" || raise inspect(got["values"])
    origin = got["origins"]["Assigned to"]
    origin["cause"] =~ ~r/^handed to ada by \S+$/ || raise inspect(origin)

    # Flow's first look on the new scene writes what is expected, and leaves Ada.
    got = expected.(i, key)
    ["Assigned to", "ada"] in got["fields"] || raise inspect(got["fields"])
    Process.sleep(500)
    {got, _} = atlas_json(i, ["get", key])
    ["Assigned to", "ada"] in got["fields"] || raise "Flow moved it: #{inspect(got["fields"])}"
  end

  # IS-Atlas-84: a scene with nothing under it is to be broken down, by whom it was handed to.
  step "Nothing under the scene: Break it down, by Ada; a use case under it moves it on", fn ->
    key = Process.get(:uc06)
    {got, _} = atlas_json(i, ["get", key])
    fields = got["fields"]
    ["Expected", "Break it down into use cases and issues"] in fields || raise inspect(fields)
    ["Assigned to", "ada"] in fields || raise inspect(fields)

    home(t1)
    open_row(t1, "A scene for Ada")
    see(t1, "No use cases yet")

    # A use case under it: a new state, so its own owner (the same name is the same key).
    atlas(i, ["put", "agent", "--name", "Coordinator"])
    {_, at} = atlas_json(i, ["put", "use_case", "--in", key, "--title", "Ada's first use case"])
    by_hint(t1, "Ada's first use case", at)

    got =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        {got, _} = atlas_json(i, ["get", key])

        if ["Assigned to", "coordinator"] in got["fields"],
          do: {:halt, got},
          else: Process.sleep(100) && {:cont, got}
      end)

    ["Assigned to", "coordinator"] in got["fields"] || raise inspect(got["fields"])
    got["origins"]["Assigned to"]["cause"] =~ "not all under it is completed" || raise inspect(got)
  end
end
