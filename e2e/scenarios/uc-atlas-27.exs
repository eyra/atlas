# UC-Atlas-27, IS-Atlas-53: Flow, first slice. One process per open fact works out its
# state from the flow definition in rela/atlas.json and writes what its owner is
# expected to do, as a change with its cause: Build it while not all under it is
# completed; Test it once all is; nothing once it is accepted; Rework, with the note,
# once it is reopened. Flow never completes anything itself. GitHub is the stand-in.
# IS-Atlas-76: a save is refused only when a field it sets changed meanwhile.
import AtlasE2E.Scenario

alias AtlasE2E.GitHub

url = "https://github.com/eyra/atlas-e2e/pull/2701"
# A connector's change shows by its hint, at most one round (2 s) after GitHub changed.
connector_wait = 5_000
# Control learns that the TUI's user is a person on its next reconcile (every 5 s).
reconcile_wait = 7_000

expected = fn i, key ->
  {got, _} = atlas_json(i, ["get", key])
  Enum.find_value(got["fields"], fn [label, value] -> label == "Expected" && value end)
end

scenario "UC-Atlas-27: Flow moves a use case to Melle when all of it is done", fn ctx ->
  %{t1: t1, instance: i} = ctx

  step "A use case with an open issue: Flow says Build it", fn ->
    # The same person again is the same fact: stored once.
    atlas_json(i, ["put", "person", "--name", "Melle"])
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene Flow moves"])

    {use_case, _} =
      atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "A use case Flow moves"])

    {issue, _} =
      atlas_json(i, ["put", "issue", "--in", use_case["key"], "--title", "Its one issue"])

    home(t1)
    open_row(t1, "A scene Flow moves")
    open_row(t1, "A use case Flow moves")
    see(t1, ~r/Expected\s+Build it/)
    expected.(i, scene["key"]) == "Build it" || raise "the scene is not Build it"

    Process.put(:uc27, %{scene: scene["key"], use_case: use_case["key"], issue: issue["key"]})
  end

  step "Its pull request merges: Test it, within a second of the merge being read", fn ->
    %{use_case: use_case, issue: issue} = Process.get(:uc27)
    pull = %{"title" => "Its one issue", "state" => "open", "merged" => false, "html_url" => url}
    GitHub.put(url, pull)
    atlas_json(i, ["put", "pull_request", "--url", url, "--in", issue])
    GitHub.put(url, %{pull | "state" => "closed", "merged" => true})

    see(t1, ~r/Expected\s+Test it/, connector_wait)
    expected.(i, use_case) == "Test it" || raise "the use case is not Test it"
    # Flow never completes anything by itself: it waits for Melle.
    {got, _} = atlas_json(i, ["get", use_case])
    progress = Enum.find_value(got["fields"], fn [l, v] -> l == "Progress" && v end)
    progress == "To test · 1/1" || raise inspect(got["fields"])
  end

  step "Accepted: done; nothing is expected of anyone", fn ->
    %{use_case: use_case} = Process.get(:uc27)
    see(t1, "a Accept", reconcile_wait)
    press(t1, "a")
    see(t1, "will be accepted by melle")
    at = press(t1, "y")
    stored(t1, ~r/Accepted by ─+(.|\n)*melle  Person/, at)
    gone(t1, "Expected")
    expected.(i, use_case) == nil || raise "something is still expected"
  end

  step "Reopened with a note: Rework, with the note", fn ->
    %{use_case: use_case} = Process.get(:uc27)
    see(t1, "a Reopen")
    press(t1, "a")
    see(t1, "Reopen #{use_case}")
    type(t1, "The footer is wrong")
    at = press(t1, "C-s")
    stored(t1, "Use case #{use_case}: A use case Flow moves", at)
    see(t1, ~r/Expected\s+Rework: The footer is wrong/)
    expected.(i, use_case) == "Rework: The footer is wrong" || raise "not Rework"
  end

  step "A new issue under it: Build it again", fn ->
    %{use_case: use_case} = Process.get(:uc27)
    # Flow writes on the use case's Assignment (IS-Atlas-78); its page is short enough to
    # show it whole, also with the use case's references grown.
    open_row(t1, "AS-#{use_case}")
    see(t1, ~r/Expected\s+Rework/)

    {fix, at} =
      atlas_json(i, ["put", "issue", "--in", use_case, "--title", "Fix the footer"])

    by_hint(t1, ~r/Expected\s+Build it/, at)
    Process.put(:uc27_fix, fix["key"])
    # Back to the use case: esc on its Assignment's page.
    press(t1, "Escape")
    see(t1, "Use case #{use_case}: A use case Flow moves")
  end

  # IS-Atlas-76: a save is refused only when a field it sets changed meanwhile.
  step "Update form open while another field changes: the save is stored", fn ->
    %{use_case: use_case} = Process.get(:uc27)
    press(t1, "u")
    see(t1, ~r/^ Update #{use_case}$/m)
    # Meanwhile someone else changes another field (as Flow changes Expected).
    atlas_json(i, ["set", use_case, "status=ready_to_pick_up"])
    type(t1, " (changed)")
    at = press(t1, "C-s")
    stored(t1, "Use case #{use_case}: A use case Flow moves (changed)", at)
    # The form left the Flux group alone, so the shell's change stays.
    {got, _} = atlas_json(i, ["get", use_case])
    got["values"]["status"] == "ready_to_pick_up" || raise inspect(got["values"])
  end

  step "Update form open while the same field changes: refused, changed meanwhile", fn ->
    %{use_case: use_case} = Process.get(:uc27)
    press(t1, "u")
    see(t1, ~r/^ Update #{use_case}$/m)
    atlas_json(i, ["set", use_case, "title=Renamed from the shell"])
    type(t1, " again")
    at = press(t1, "C-s")
    stored(t1, "#{use_case} changed meanwhile; open it again", at)
    press(t1, "Escape")
    see(t1, "Use case #{use_case}: Renamed from the shell")
  end

  # The scenes list stays short enough for the scenarios after this one.
  step "Clean up: delete what this scenario made", fn ->
    %{scene: scene, use_case: use_case, issue: issue} = Process.get(:uc27)
    home(t1)
    {_, 0, _} = atlas(i, ["delete", "PR-eyra-atlas-e2e-2701"])

    for key <- [Process.get(:uc27_fix), issue, use_case, scene],
        do: {_, 0, _} = atlas(i, ["delete", key])

    gone(t1, "A scene Flow moves")
  end
end
