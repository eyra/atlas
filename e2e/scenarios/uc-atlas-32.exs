# UC-Atlas-32: completed means accepted or merged; completable is an association
# (docs/guides/uc-atlas-32.md).
# IS-Atlas-62: a person, and accepted_by from a use case to that person, shown with the
# fact that set it (since, by whom, why); done_in is history only.
# IS-Atlas-63: State works out completed: an issue when its pull request is merged (on
# the stand-in GitHub), a use case when it is accepted; a parent is to test, never done,
# because its children are.
# IS-Atlas-64: Accept (a) and Reopen (r), in the TUI, for a person only; an agent is
# refused; nothing new goes under an accepted use case.
import AtlasE2E.Scenario

alias AtlasE2E.GitHub

url = "https://github.com/eyra/atlas-e2e/pull/3201"
# A connector's change shows by its hint, at most one round (2 s) after GitHub changed.
connector_wait = 5_000
# Control learns that the TUI's user is a person on its next reconcile (every 5 s).
reconcile_wait = 7_000

scenario "UC-Atlas-32: Completed means accepted or merged", fn %{t1: t1, instance: i} ->
  step "A person, made from its name; not on the start page", fn ->
    {person, _} = atlas_json(i, ["put", "person", "--name", "Melle"])
    person["key"] == "melle" || raise inspect(person)
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene to accept"])

    {use_case, _} =
      atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "A use case to accept"])

    {issue, _} =
      atlas_json(i, ["put", "issue", "--in", use_case["key"], "--title", "Its only issue"])

    home(t1)
    see(t1, "A scene to accept")
    refute_see(t1, "People")
    open_row(t1, "A scene to accept")
    open_row(t1, "A use case to accept")
    see(t1, "Use case #{use_case["key"]}: A use case to accept")
    refute_see(t1, "Accepted by")

    Process.put(:uc32, %{scene: scene["key"], use_case: use_case["key"], issue: issue["key"]})
  end

  step "Only a person accepts: the command line is refused, and its tools do not offer it",
       fn ->
         %{use_case: use_case, issue: issue} = Process.get(:uc32)
         {%{"refused" => [why]}, _} = atlas_json(i, ["set", use_case, "accepted_by=melle"], 1)
         why =~ "only a person accepts" || raise why
         {%{"refused" => [why]}, _} = atlas_json(i, ["set", issue, "done_in=PR-eyra-atlas-1"], 1)
         why =~ "only a migration sets it" || raise why
         {tools, 0, _} = atlas(i, ["tools"])

         if String.contains?(tools, "accepted_by") or String.contains?(tools, "done_in"),
           do: raise("atlas tools offers accepted_by or done_in:\n" <> tools)
       end

  step "a Accept is refused while an issue is open, and says which", fn ->
    %{use_case: use_case, issue: issue} = Process.get(:uc32)
    see(t1, "a Accept", reconcile_wait)
    press(t1, "a")
    see(t1, "#{use_case} has #{issue} open")
    press(t1, "Escape")
    see(t1, "Use case #{use_case}: A use case to accept")
  end

  step "An issue whose pull request merges is Done, set by nobody; its use case to test", fn ->
    %{use_case: use_case, issue: issue} = Process.get(:uc32)
    pull = %{"title" => "Its only issue", "state" => "open", "merged" => false, "html_url" => url}
    GitHub.put(url, pull)
    {_, at} = atlas_json(i, ["put", "pull_request", "--url", url, "--in", issue])
    by_hint(t1, ~r/#{issue}\s+Its only issue\s+Specification/, at)

    GitHub.put(url, %{pull | "state" => "closed", "merged" => true})
    see(t1, ~r/#{issue}\s+Its only issue\s+Done/, connector_wait)

    {got, _} = atlas_json(i, ["get", issue])
    progress = Enum.find_value(got["fields"], fn [l, v] -> l == "Progress" && v end)
    progress == "Done · PR-eyra-atlas-e2e-3201 merged" || raise inspect(got["fields"])

    # The use case is not done because its issue is: it is to test.
    press(t1, "Escape")
    see(t1, ~r/#{use_case}\s+A use case to accept\s+To test · 1\/1/)
  end

  step "a Accept, y: the use case is Done, accepted by melle; the scene to test", fn ->
    %{scene: scene, use_case: use_case} = Process.get(:uc32)
    open_row(t1, "A use case to accept")
    press(t1, "a")
    see(t1, "will be accepted by melle")
    at = press(t1, "y")
    stored(t1, ~r/Accepted by ─+(.|\n)*melle  Person/, at)
    see(t1, "r Reopen")
    refute_see(t1, "r refresh")

    {got, _} = atlas_json(i, ["get", use_case])
    progress = Enum.find_value(got["fields"], fn [l, v] -> l == "Progress" && v end)
    progress == "Done · 1/1 · accepted by melle" || raise inspect(got["fields"])
    got["origins"]["Progress"]["by"] == "melle" || raise inspect(got["origins"])

    press(t1, "Escape")
    see(t1, ~r/#{use_case}\s+A use case to accept\s+Done · 1\/1/)
    press(t1, "Escape")
    see(t1, ~r/#{scene}\s+A scene to accept\s+To test · 1\/1/)
  end

  step "Nothing new goes under an accepted use case", fn ->
    %{use_case: use_case} = Process.get(:uc32)

    {%{"refused" => [why]}, _} =
      atlas_json(i, ["put", "issue", "--in", use_case, "--title", "Late"], 1)

    why == "#{use_case} is accepted; reopen it first, or put this under another use case" ||
      raise why
  end

  step "r Reopen asks for a note; the use case is to test again, with the note", fn ->
    %{use_case: use_case} = Process.get(:uc32)
    open_row(t1, "A scene to accept")
    open_row(t1, "A use case to accept")
    press(t1, "r")
    see(t1, "Reopen #{use_case}")
    type(t1, "Found a bug in the footer")
    at = press(t1, "C-s")
    stored(t1, "Use case #{use_case}: A use case to accept", at)
    see(t1, "a Accept")
    press(t1, "Tab")
    press(t1, ["j", "j", "j", "j"])
    see(t1, "by melle · Found a bug in the footer")
    press(t1, ["k", "k", "k", "k", "Tab", "Escape"])
    see(t1, ~r/#{use_case}\s+A use case to accept\s+To test · 1\/1/)
  end
end
