# UC-Atlas-03: manage the issues of a use case (docs/guides/uc-atlas-03.md).
import AtlasE2E.Scenario

scenario "UC-Atlas-03: Manage the issues of a use case", fn %{t1: t1, t2: t2} ->
  use_case = ~r/Use case UC-Atlas-\d+: A use case with issues/

  step "A use case, with no issues yet", fn ->
    press(t1, "n")
    see(t1, ~r/^ New scene$/m)
    type(t1, "A scene for issues")
    at = press(t1, "C-s")
    stored(t1, ~r/Scene SC-Atlas-\d+: A scene for issues/, at)
    press(t1, "a")
    see(t1, ~r/^ New use case in SC-Atlas-\d+$/m)
    type(t1, "A use case with issues")
    at = press(t1, "C-s")
    stored(t1, use_case, at)
    see(t1, "No issues yet. Press a to add one.")

    by_hint(t2, "A scene for issues", at)
    open_row(t2, "A scene for issues")
    see(t2, "A use case with issues")
    open_row(t2, "A use case with issues")
    see(t2, use_case)
  end

  step "Add an issue: title and description only, a made code, stage by default", fn ->
    press(t1, "a")
    see(t1, ~r/^ New issue in UC-Atlas-\d+$/m)
    for field <- ["Stage", "Completed", "Flux ref", "Flux id"], do: refute_see(t1, field)
    type(t1, "Write the first issue")
    press(t1, "Down")
    type(t1, "Small, independently testable work.")
    at = press(t1, "C-s")
    stored(t1, ~r/✓ Stored as IS-Atlas-\d+/, at)
    page = stored(t1, ~r/Issue IS-Atlas-\d+: Write the first issue/, at)
    page =~ ~r/Stage\s+Specification/ || raise "the stage is not Specification"
    page =~ ~r/Completed\s+no/ || raise "completed is not no"
    page =~ ~r/In use case\s+UC-Atlas-\d+/ || raise "it is not in the use case"
    for field <- ["Flux ref", "Flux id", "Status"], do: refute_see(t1, field)
    see(t1, "No pull requests yet.")
    by_hint(t2, "Write the first issue", at)
  end

  step "Change: the code read-only, no Flux fields; stage and completed", fn ->
    press(t1, "e")
    see(t1, ~r/Change issue IS-Atlas-\d+/)
    see(t1, ~r/Id\s+IS-Atlas-\d+/)
    for field <- ["Flux ref", "Flux id"], do: refute_see(t1, field)
    # Title, then the stage (one to the right: Design), then completed (yes).
    press(t1, ["Down", "Right"])
    see(t1, "‹ Design ›")
    press(t1, ["Down", "Right"])
    see(t1, "‹ yes ›")
    at = press(t1, "C-s")
    page = stored(t1, ~r/Stage\s+Design/, at)
    page =~ ~r/Completed\s+yes/ || raise "completed is not yes"
    by_hint(t2, ~r/IS-Atlas-\d+  .*  Design · completed/, at)
  end

  step "Remove it; back in the use case; TUI 2 by hint", fn ->
    press(t1, "d")
    see(t1, ~r/Delete issue IS-Atlas-\d+\?/)
    at = press(t1, "y")
    stored(t1, use_case, at)
    see(t1, "No issues yet.")
    by_hint(t2, "Write the first issue", at, gone: true)
  end

  step "A use case with an issue cannot be deleted", fn ->
    press(t1, "a")
    see(t1, ~r/^ New issue in UC-Atlas-\d+$/m)
    type(t1, "An issue that stays")
    at = press(t1, "C-s")
    stored(t1, ~r/Issue IS-Atlas-\d+: An issue that stays/, at)
    press(t1, "Escape")
    see(t1, use_case)
    press(t1, "d")
    see(t1, "cannot be deleted")
    see(t1, ~r/still has 1 issue\. Remove it first/)
    press(t1, "Enter")
    see(t1, use_case)
  end
end
