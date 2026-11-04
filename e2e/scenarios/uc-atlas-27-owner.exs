# UC-Atlas-27: every fact has an owner. IS-Atlas-52: the owner is the association
# assigned_to, from every assignable kind to a person or an agent, at most one; the link
# shows with the fact that set it (since, by, cause), and the owner's page lists what is
# assigned to it. `atlas migrate-owner` gave every fact without one the coordinator; since
# IS-Atlas-75 Flow gives every new fact its owner, so it has nothing to give a new one.
import AtlasE2E.Scenario

scenario "UC-Atlas-27: Every fact has an owner", fn %{t1: t1, t2: t2, instance: i} ->
  step "Who can own: a person and an agent, each made from its name", fn ->
    # A person of this scenario's own; UC-Atlas-32 makes melle.
    {person, _} = atlas_json(i, ["put", "person", "--name", "Ann"])
    person["key"] == "ann" || raise inspect(person)
    {agent, _} = atlas_json(i, ["put", "agent", "--name", "Coordinator"])
    agent["key"] == "coordinator" || raise inspect(agent)
    {got, _} = atlas_json(i, ["get", "ann"])
    got["title"] == "Person ann: Ann" || raise inspect(got)
  end

  step "An owner set from the command line, with its cause; both TUIs show it by hint", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene with an owner"])
    key = scene["key"]
    Process.put(:uc27, key)

    for t <- [t1, t2] do
      home(t)
      open_row(t, "A scene with an owner")
      see(t, "Scene #{key}: A scene with an owner")
    end

    {got, at} =
      atlas_json(i, ["set", key, "assigned_to=coordinator", "--cause", "owner introduced"])

    origin = got["origins"]["Assigned to"]
    origin["cause"] == "owner introduced" || raise inspect(got)
    origin["by"] == "agent" || raise inspect(origin)
    origin["since"] =~ ~r/^\d{4}-\d\d-\d\dT/ || raise inspect(origin)

    for t <- [t1, t2], do: by_hint(t, ~r/Assigned to ─+(.|\n)*coordinator  Agent/, at)
  end

  step "The owner moves: one owner, the new one, with its own cause", fn ->
    key = Process.get(:uc27)

    {got, at} =
      atlas_json(i, ["set", key, "assigned_to=ann", "--cause", "all its issues are done"])

    ["Assigned to", "ann"] in got["fields"] || raise inspect(got["fields"])
    got["origins"]["Assigned to"]["cause"] == "all its issues are done" || raise inspect(got)
    by_hint(t1, ~r/Assigned to ─+(.|\n)*ann  Person/, at)
    refute_see(t1, "coordinator  Agent")

    {text, 0, _} = atlas(i, ["get", key])

    text =~ ~r/Assigned to: ann \(since \d+ \w+ \d\d:\d\d, by agent: all its issues are done\)/ ||
      raise text
  end

  step "Only a person or an agent can own", fn ->
    key = Process.get(:uc27)
    {%{"refused" => [why]}, _} = atlas_json(i, ["set", key, "assigned_to=nobody"], 1)
    why == "nobody is not a person or agent" || raise why
  end

  step "enter on the owner opens it, with what is assigned to it", fn ->
    key = Process.get(:uc27)
    open_row(t1, "ann  Person")
    see(t1, "Person ann: Ann")
    # Since IS-Atlas-78 what is assigned is an Assignment, named by its fact.
    see(t1, "Assignments")
    see(t1, ~r/AS-#{key}\s+#{key}/)
  end

  # IS-Atlas-75: Flow gives a new fact its owner from the flow's rule, so the migration
  # that gave every fact without one the coordinator has nothing to give it.
  step "A new fact gets its owner from Flow; atlas migrate-owner leaves it alone", fn ->
    {lone, _} = atlas_json(i, ["put", "scene", "--title", "A scene Flow assigns"])

    got =
      Enum.reduce_while(1..40, nil, fn _, _ ->
        {got, _} = atlas_json(i, ["get", lone["key"]])

        if ["Assigned to", "coordinator"] in got["fields"],
          do: {:halt, got},
          else:
            (
              Process.sleep(100)
              {:cont, got}
            )
      end)

    ["Assigned to", "coordinator"] in got["fields"] || raise inspect(got["fields"])
    got["origins"]["Assigned to"]["by"] == "flow" || raise inspect(got["origins"])

    # The migration would still give a done fact the coordinator; Flow leaves it nobody.
    {out, 0, _} = atlas(i, ["migrate-owner", "--dry-run"])

    String.contains?(out, "AS-#{lone["key"]}") &&
      raise "the migration would move its owner:\n" <> out
  end
end
