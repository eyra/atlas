# UC-Atlas-02: manage the use cases of a scene (docs/guides/uc-atlas-02.md).
import AtlasE2E.Scenario

scenario "UC-Atlas-02: Manage the use cases of a scene", fn %{t1: t1, t2: t2} ->
  step "A scene, with no use cases yet", fn ->
    press(t1, "c")
    see(t1, ~r/^ Create scene$/m)
    type(t1, "A scene with use cases")
    at = press(t1, "C-s")
    stored(t1, "No use cases yet. Press c to create one.", at)
    Process.put(:scene, capture(t1, ~r/Scene (SC-Atlas-\d+): A scene with use cases/))
    by_hint(t2, "A scene with use cases", at)
    open_row(t2, "A scene with use cases")
    see(t2, "No use cases yet.")
  end

  step "Add a use case: title and description only, a made code", fn ->
    scene = Process.get(:scene)
    press(t1, "c")
    see(t1, "Create use case in #{scene}")
    for field <- ["Flux group", "Status", "Completed", "Flux id"], do: refute_see(t1, field)
    type(t1, "Add the first use case")
    press(t1, "Down")
    type(t1, "Made by the end-to-end test.")
    at = press(t1, "C-s")
    stored(t1, ~r/✓ Stored as UC-Atlas-\d+/, at)
    stored(t1, ~r/In scene[\s─│]+#{scene}/u, at)
    by_hint(t2, "Add the first use case", at)
  end

  step "Back, and a second one", fn ->
    press(t1, "Escape")
    see(t1, ~r/Scene SC-Atlas-\d+: A scene with use cases/)
    see(t1, "Add the first use case")
    press(t1, "c")
    see(t1, ~r/^ Create use case in SC-Atlas-\d+$/m)
    type(t1, "Add a second use case")
    at = press(t1, "C-s")
    stored(t1, ~r/Use case UC-Atlas-\d+: Add a second use case/, at)
    by_hint(t2, "Add a second use case", at)
  end

  step "Open one: its defaults", fn ->
    press(t1, "Escape")
    see(t1, ~r/Scene SC-Atlas-\d+: A scene with use cases/)
    open_row(t1, "Add the first use case")
    see(t1, ~r/Flux group\s+Refine/)
  end

  step "Update it; TUI 2 follows by hint", fn ->
    press(t1, "u")
    see(t1, ~r/Update UC-Atlas-\d+/)
    type(t1, " (changed)")
    at = press(t1, "C-s")
    stored(t1, ~r/Use case UC-Atlas-\d+: Add the first use case \(changed\)/, at)
    by_hint(t2, "Add the first use case (changed)", at)
  end

  step "No title is refused, and the form keeps what was typed", fn ->
    press(t1, "Escape")
    see(t1, ~r/Scene SC-Atlas-\d+: A scene with use cases/)
    press(t1, "c")
    see(t1, ~r/^ Create use case in SC-Atlas-\d+$/m)
    press(t1, "Down")
    type(t1, "only a description")
    at = press(t1, "C-s")
    stored(t1, "title is required", at)
    see(t1, "only a description")
    press(t1, "Escape")
    see(t1, ~r/Scene SC-Atlas-\d+: A scene with use cases/)
  end

  step "Remove one; back in the scene; TUI 2 follows by hint", fn ->
    open_row(t1, "Add a second use case")
    see(t1, ~r/Use case UC-Atlas-\d+: Add a second use case/)
    press(t1, "d")
    see(t1, ~r/Delete use case UC-Atlas-\d+\?/)
    at = press(t1, "y")
    stored(t1, ~r/Scene SC-Atlas-\d+: A scene with use cases/, at)
    gone(t1, "Add a second use case", 1_000)
    by_hint(t2, "Add a second use case", at, gone: true)
  end

  step "A scene with use cases cannot be deleted", fn ->
    press(t1, "d")
    see(t1, "cannot be deleted")
    see(t1, ~r/still has 1 use case\. Remove it first/)
    see(t1, "Atlas never deletes it along with its parent")
    press(t1, "Enter")
    see(t1, ~r/Scene SC-Atlas-\d+: A scene with use cases/)
  end
end
