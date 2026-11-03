# UC-Atlas-16: Control's actions as the agent's tools, and a plan that writes nothing
# (docs/guides/uc-atlas-16.md). The planner is the instance's scripted stand-in
# (e2e/fixtures/planner.exs), so no model is needed.
import AtlasE2E.Scenario

scenario "UC-Atlas-16: The agent's tools and plans, from rela's description", fn %{
                                                                                   t1: t1,
                                                                                   instance: i
                                                                                 } ->
  description = """
  Melle plans his week in Atlas.

  - Plan the week from the scenes
  - See what is late
  - Hand work to an agent
  """

  step "A scene with use cases in its description; TUI 1 shows it", fn ->
    {scene, at} =
      atlas_json(
        i,
        ["put", "scene", "--title", "A scene to plan from", "--description", "-"],
        0,
        description
      )

    Process.put(:scene, scene["key"])
    by_hint(t1, "A scene to plan from", at)
    open_row(t1, "A scene to plan from")
    see(t1, "No use cases yet.")
  end

  step "The tools come from rela's description: a put and a set per kind, and the reads", fn ->
    {tools, _} = atlas_json(i, ["tools"])
    puts = for %{"tool" => "put"} = t <- tools, into: %{}, do: {t["kind"], t}
    sets = for %{"tool" => "set"} = t <- tools, do: t["kind"]

    Enum.sort(Map.keys(puts)) == ~w(issue pull_request scene use_case) ||
      raise inspect(Map.keys(puts))

    Enum.sort(sets) == Enum.sort(Map.keys(puts)) || raise inspect(sets)

    use_case = puts["use_case"]
    use_case["in"] == "scene" || raise inspect(use_case)

    Enum.map(use_case["asks"], & &1["name"]) == ["title", "description"] ||
      raise inspect(use_case)

    use_case["title"] == "Create use case" || raise inspect(use_case)
    puts["scene"]["in"] == nil || raise inspect(puts["scene"])

    for read <- ~w(get list help),
        do: Enum.any?(tools, &(&1["tool"] == read)) || raise("no #{read} tool")

    {text, 0, _} = atlas(i, ["tools"])

    text =~ "atlas put use_case --in <scene key> --title <text> --description <lines>" ||
      raise text
  end

  step "A plan from the page's description: one step per use case; nothing written", fn ->
    scene = Process.get(:scene)

    {plan, _} =
      atlas_json(i, ["plan", "--on", scene, "propose use cases from this scene's description"])

    plan["by"] == "the e2e stand-in" || raise inspect(plan)
    plan["on"] == "/k/scene/#{scene}" || raise inspect(plan)
    [first, _, third] = plan["steps"] || raise inspect(plan)

    first["label"] == "Create use case in #{scene}" || raise inspect(first)
    first["problem"] == nil || raise inspect(first)

    Enum.map(first["inputs"], &{&1["name"], &1["value"]}) ==
      [{"title", "Plan the week from the scenes"}, {"description", "Proposed from #{scene}."}] ||
      raise inspect(first["inputs"])

    third["n"] == 3 || raise inspect(third)

    # Nothing was written: no use case under the scene, in Control or on TUI 1.
    {got, _} = atlas_json(i, ["get", scene])
    hd(got["lists"])["rows"] == [] || raise inspect(got["lists"])
    see(t1, "No use cases yet.")
  end

  step "A step Control's form does not allow is caught before anyone sees it run", fn ->
    scene = Process.get(:scene)
    {plan, _} = atlas_json(i, ["plan", "--on", scene, "colour it red"])
    [step] = plan["steps"]
    step["label"] == "Update #{scene}" || raise inspect(step)
    step["problem"] =~ "does not ask for colour" || raise inspect(step)

    {text, 0, _} = atlas(i, ["plan", "--on", scene, "colour it red"])
    text =~ "✗ Update #{scene} does not ask for colour" || raise text
    text =~ "Nothing was written." || raise text
  end
end
