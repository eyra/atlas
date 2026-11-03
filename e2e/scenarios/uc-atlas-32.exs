# UC-Atlas-32: completed means accepted or merged; completable is an association.
# IS-Atlas-62: a person, and accepted_by from a use case to that person, shown with the
# fact that set it (since, by whom, why); done_in is history only.
# IS-Atlas-63: State works out completed: an issue when its pull request is merged (on
# the stand-in GitHub), a use case when it is accepted; a parent is to test, never done,
# because its children are.
import AtlasE2E.Scenario

alias AtlasE2E.GitHub

url = "https://github.com/eyra/atlas-e2e/pull/3201"
# A connector's change shows by its hint, at most one round (2 s) after GitHub changed.
connector_wait = 5_000

scenario "UC-Atlas-32: Completed means accepted or merged", fn %{t1: t1, instance: i} ->
  step "A person, made from its name; not on the start page", fn ->
    {person, _} = atlas_json(i, ["put", "person", "--name", "Melle"])
    person["key"] == "melle" || raise inspect(person)
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene to accept"])

    {use_case, _} =
      atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "A use case to accept"])

    {issue, _} =
      atlas_json(i, ["put", "issue", "--in", use_case["key"], "--title", "Its only issue"])

    Process.put(:uc32_scene, scene["key"])

    home(t1)
    see(t1, "A scene to accept")
    refute_see(t1, "People")
    open_row(t1, "A scene to accept")
    open_row(t1, "A use case to accept")
    see(t1, "Use case #{use_case["key"]}: A use case to accept")
    refute_see(t1, "Accepted by")
    Process.put(:uc32, %{use_case: use_case["key"], issue: issue["key"]})
  end

  step "accepted_by: TUI 1 shows who, since when, by whom and why, by hint", fn ->
    %{use_case: use_case} = Process.get(:uc32)

    {got, at} =
      atlas_json(i, ["set", use_case, "accepted_by=melle", "--cause", "tested it in the e2e"])

    got["origins"]["Accepted by"]["cause"] == "tested it in the e2e" || raise inspect(got)
    # In the references, the person it points at; in the content, with its origin.
    by_hint(t1, ~r/Accepted by ─+(.|\n)*melle  Person/, at)
    press(t1, "Tab")
    see(t1, "↑↓ scroll")
    press(t1, ["j", "j", "j"])
    see(t1, ~r/Accepted by\s+melle/)
    see(t1, ~r/since \d+ \w+ \d\d:\d\d · by agent · tested it in the e2e/)
  end

  step "Removing it is a fact too: the page says it was removed, by whom and why", fn ->
    %{use_case: use_case} = Process.get(:uc32)
    {_, at} = atlas_json(i, ["set", use_case, "accepted_by=", "--cause", "found a bug"])
    by_hint(t1, "by agent · found a bug", at)
    see(t1, ~r/Accepted by\s+—/)
    refute_see(t1, "melle  Person")
    press(t1, ["k", "k", "k", "Tab"])
  end

  step "done_in is history only: no client sets it", fn ->
    %{issue: issue} = Process.get(:uc32)
    {%{"refused" => [why]}, _} = atlas_json(i, ["set", issue, "done_in=PR-eyra-atlas-1"], 1)
    why =~ "only a migration sets it" || raise why
    {tools, 0, _} = atlas(i, ["tools"])
    String.contains?(tools, "done_in") && raise "atlas tools offers done_in:\n" <> tools
  end

  step "An issue whose pull request merges is Done, set by nobody; its use case to test", fn ->
    %{use_case: use_case, issue: issue} = Process.get(:uc32)
    pull = %{"title" => "Its only issue", "state" => "open", "merged" => false, "html_url" => url}
    GitHub.put(url, pull)
    {_, at} = atlas_json(i, ["put", "pull_request", "--url", url, "--in", issue])
    # While its pull request is open it shows Development (IS-Atlas-61).
    by_hint(t1, ~r/#{issue}\s+Its only issue\s+Development/, at)

    GitHub.put(url, %{pull | "state" => "closed", "merged" => true})
    see(t1, ~r/#{issue}\s+Its only issue\s+Done/, connector_wait)

    {got, _} = atlas_json(i, ["get", issue])
    progress = Enum.find_value(got["fields"], fn [l, v] -> l == "Progress" && v end)
    progress == "Done · PR-eyra-atlas-e2e-3201 merged" || raise inspect(got["fields"])

    # The use case is not done because its issue is: it is to test.
    press(t1, "Escape")
    see(t1, ~r/#{use_case}\s+A use case to accept\s+To test · 1\/1/)
  end

  step "Accepted: the use case is Done; the scene is to test", fn ->
    %{use_case: use_case} = Process.get(:uc32)
    scene = Process.get(:uc32_scene)
    {_, at} = atlas_json(i, ["set", use_case, "accepted_by=melle", "--cause", "tested"])
    by_hint(t1, ~r/#{use_case}\s+A use case to accept\s+Done · 1\/1/, at)
    see(t1, ~r/Progress\s+To test · 1\/1/)

    {got, _} = atlas_json(i, ["get", use_case])
    progress = Enum.find_value(got["fields"], fn [l, v] -> l == "Progress" && v end)
    progress == "Done · 1/1 · accepted by melle" || raise inspect(got["fields"])
    got["origins"]["Progress"]["cause"] == "tested" || raise inspect(got["origins"])

    press(t1, "Escape")
    see(t1, ~r/#{scene}\s+A scene to accept\s+To test · 1\/1/)
  end
end
