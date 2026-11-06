# UC-Atlas-17: ask with `:` and decide on the plan (docs/guides/uc-atlas-17.md). The
# first real case: propose use cases from a scene's description; keep, edit or drop
# each. The planner is the instance's scripted stand-in (e2e/fixtures/planner.exs).
import AtlasE2E.Scenario

scenario "UC-Atlas-17: Ask in the TUI and see the plan", fn %{t1: t1, t2: t2, instance: i} ->
  description = """
  Melle asks Atlas for the use cases of this scene.

  - Ask from any page
  - Drop a step
  - Edit a step
  """

  # A use case in the scene's list, not the same words in its description.
  row = fn title -> ~r/UC-Atlas-\d+\s+#{Regex.escape(title)}/ end

  step "A scene with use cases in its description, open in both TUIs", fn ->
    {scene, _} =
      atlas_json(
        i,
        ["put", "scene", "--title", "A scene to ask about", "--description", "-"],
        0,
        description
      )

    Process.put(:scene, scene["key"])

    for t <- [t1, t2] do
      open_row(t, "A scene to ask about")
      see(t, "No use cases yet.")
    end
  end

  step "`:` opens the request line; enter shows the plan; nothing is written yet", fn ->
    scene = Process.get(:scene)
    press(t1, ":")
    type(t1, "propose use cases from this scene's description")
    see(t1, "propose use cases from this scene's description")
    press(t1, "Enter")
    see(t1, "Proposed: 3 steps", 10_000)
    see(t1, "You asked       propose use cases from this scene's description")
    see(t1, "By              the e2e stand-in")
    see(t1, "› [✓] 1. Create use case in #{scene}")
    see(t1, "[✓] 3. Create use case in #{scene}")
    see_action(t1, "Space", "Keep or drop step")
    see_action(t1, "e", "Edit step")
    see_action(t1, "Enter", "Run kept steps")
    see(t2, "No use cases yet.")
  end

  step "space drops a step; e edits one in its form, ctrl-s keeps the edit", fn ->
    press(t1, ["Down", "Space"])
    see(t1, "[ ] 2. Create use case in")
    press(t1, ["Down", "e"])
    see(t1, ~r/Step 3: Create use case in SC-Atlas-\d+/)
    see(t1, "[ Keep ]")
    type(t1, " (edited)")
    press(t1, "C-s")
    see(t1, "Edit a step (edited)")
    see(t1, "Proposed: 3 steps")
  end

  step "enter runs the kept steps through Control; TUI 2 shows them by hint", fn ->
    at = press(t1, "Enter")
    by_hint(t2, row.("Ask from any page"), at)
    see(t1, "Done: 2 of 2 stored", 10_000)
    see(t1, ~r/Stored as UC-Atlas-\d+\./)
    see(t2, row.("Edit a step (edited)"))
    refute_see(t2, row.("Drop a step"))
  end

  step "Closing the plan shows the scene with the two new use cases", fn ->
    press(t1, "Enter")
    see(t1, row.("Ask from any page"))
    see(t1, row.("Edit a step (edited)"))
    refute_see(t1, row.("Drop a step"))
  end

  step "esc cancels a plan: nothing is written", fn ->
    scene = Process.get(:scene)
    press(t1, ":")
    type(t1, "propose use cases from this scene's description")
    press(t1, "Enter")
    see(t1, "Proposed: 3 steps", 10_000)
    press(t1, "Escape")
    see_action(t1, "u", "Update scene")
    see_action(t1, "d", "Delete scene")
    {got, _} = atlas_json(i, ["get", scene])
    length(hd(got["lists"])["rows"]) == 2 || raise inspect(got["lists"])
  end

  step "A request with nothing to do says so; a step a form does not allow is caught", fn ->
    press(t1, ":")
    type(t1, "hello")
    press(t1, "Enter")
    see(t1, "No steps proposed", 10_000)
    see(t1, "Nothing to do for this request.")
    press(t1, "Escape")
    press(t1, ":")
    type(t1, "colour it red")
    press(t1, "Enter")
    see(t1, "[!] 1. Update SC-Atlas-", 10_000)
    see(t1, "does not ask for colour")
    {before_run, _} = atlas_json(i, ["get", Process.get(:scene)])
    press(t1, "Enter")
    press(t1, "Escape")
    see_action(t1, "u", "Update scene")
    see_action(t1, "d", "Delete scene")
    {after_run, _} = atlas_json(i, ["get", Process.get(:scene)])

    (after_run["values"] == before_run["values"] && after_run["lists"] == before_run["lists"]) ||
      raise "Blocked plan changed the scene"
  end
end
