# UC-Atlas-18: run, follow and stop the steps (docs/guides/uc-atlas-18.md). The instance
# waits agent.step_pause_ms (500) between steps, so each one can be seen, and stopped.
import AtlasE2E.Scenario

scenario "UC-Atlas-18: Run, follow and stop the steps", fn %{t1: t1, t2: t2, instance: i} ->
  description = """
  Melle watches the agent work.

  - Watch the first step
  - Watch the second step
  - Watch the third step
  """

  row = fn title -> ~r/#{Regex.escape(title)}\s+UC-Atlas-\d+/ end

  scene = fn title ->
    {scene, at} =
      atlas_json(i, ["put", "scene", "--title", title, "--description", "-"], 0, description)

    for t <- [t1, t2], do: by_hint(t, title, at)

    for t <- [t1, t2] do
      open_row(t, title)
      see(t, "No use cases yet.")
    end

    scene["key"]
  end

  ask = fn ->
    press(t1, ":")
    type(t1, "propose use cases from this scene's description")
    press(t1, "Enter")
    see(t1, "Proposed: 3 steps", 10_000)
  end

  step "Each step shows as it runs; TUI 2 shows each by hint", fn ->
    scene.("A scene to watch")
    ask.()
    at = press(t1, "Enter")
    see(t1, "Running: 1 of 3 stored")
    by_hint(t2, row.("Watch the first step"), at)
    refute_see(t2, row.("Watch the third step"))
    see(t1, "esc stop after this step")
    see(t1, "Done: 3 of 3 stored", 5_000)
    see(t2, row.("Watch the third step"))
    press(t1, "Enter")
    for t <- [t1, t2], do: home(t)
  end

  step "esc stops the run before its next step; stored steps stay", fn ->
    key = scene.("A scene to stop")
    ask.()
    press(t1, "Enter")
    see(t1, "Running: 1 of 3 stored")
    press(t1, "Escape")
    see(t1, "Stopped: 1 of 3 stored", 3_000)
    screen = see(t1, "Not run: stopped before it.")
    length(String.split(screen, "Not run: stopped before it.")) == 3 || raise screen
    refute_see(t1, "Stopping after this step")

    {got, _} = atlas_json(i, ["get", key])
    [%{"label" => "Watch the first step"}] = hd(got["lists"])["rows"]
    see(t2, row.("Watch the first step"))
    refute_see(t2, row.("Watch the second step"))

    press(t1, "Enter")
    see(t1, row.("Watch the first step"))
    for t <- [t1, t2], do: home(t)
  end

  step "A refused step stops the run; the agent says why and proposes the rest", fn ->
    key = scene.("A scene with a refusal")
    ask.()
    # Step 2 loses its title, which a create requires.
    press(t1, ["Down", "e"])
    see(t1, "[ Keep ]")
    press(t1, List.duplicate("BSpace", 30))
    press(t1, "C-s")
    see(t1, "Proposed: 3 steps")
    press(t1, "Enter")
    see(t1, "Proposed: 1 step", 5_000)
    see(t1, ~r/Before\s+Step 2 \(New use case in #{key}\) was refused: title is required\./)
    see(t1, ~r/Stored\s+before\s+it:\s+step\s+1\./)
    see(t1, ~r/Not\s+run:\s+step\s+3\./)
    see(t1, "[✓] 1. New use case in #{key}")
    see(t1, "Watch the third step")

    {got, _} = atlas_json(i, ["get", key])
    [%{"label" => "Watch the first step"}] = hd(got["lists"])["rows"]

    # The proposal runs only on enter, like any plan.
    press(t1, "Enter")
    see(t1, "Done: 1 of 1 stored", 5_000)
    {got, _} = atlas_json(i, ["get", key])
    2 = length(hd(got["lists"])["rows"])
    press(t1, "Enter")
    for t <- [t1, t2], do: home(t)
  end

  step "State refuses when the scene is gone; what next cannot run there either", fn ->
    key = scene.("A scene that goes away")
    ask.()
    # TUI 2 deletes the scene before the plan runs.
    press(t2, "d")
    see(t2, "Delete scene #{key}?")
    press(t2, "y")
    gone(t2, "A scene that goes away")
    press(t1, "Enter")

    see(
      t1,
      ~r/Before\s+Step 1 \(New use case in #{key}\) was refused: #{key} does not exist/,
      5_000
    )

    see(t1, ~r/Nothing\s+was\s+stored\./)
    see(t1, "#{key} is not a scene in Atlas")
    press(t1, "Enter")
    see(t1, "Step 1, 2 cannot run; drop it with space.")
    press(t1, "Escape")
    for t <- [t1, t2], do: home(t)
  end

  step "A plan of one step runs without asking; a longer one still asks", fn ->
    key = scene.("A scene to rename")
    press(t1, ":")
    type(t1, "rename to A renamed scene")
    press(t1, "Enter")
    see(t1, "Done: 1 of 1 stored, without asking", 10_000)
    see(t1, "[✓] 1. Change scene #{key}")
    # Planning comes first, so this is not the 1-second hint of a save.
    see(t2, "Scene #{key}: A renamed scene", 5_000)
    press(t1, "Enter")
    see(t1, "Scene #{key}: A renamed scene")

    # Three steps: it asks.
    ask.()
    refute_see(t1, "without asking")
    press(t1, "Escape")
  end
end
