# UC-Atlas-29, IS-Atlas-56: test a use case from My work, and answer. The answers are the
# flow definition's (the state's todo.answers): on the page and in the footer, for its
# owner only. Accept is IS-Atlas-64's accepted_by, reused; Reject asks only for a note and
# removes it, so Flow reads it as reopened: back to the coordinator, with the note.
import AtlasE2E.Scenario

alias AtlasE2E.GitHub

# A connector's change shows by its hint, at most one round (2 s) after GitHub changed.
connector_wait = 5_000

# `atlas get`'s value for `label` in `key`, once it is `want` (Flow writes within moments).
shows = fn i, key, label, want ->
  Enum.reduce_while(1..50, nil, fn _, _ ->
    {got, _} = atlas_json(i, ["get", key])
    value = Enum.find_value(got["fields"], fn [l, v] -> l == label && v end)
    if value == want, do: {:halt, value}, else: Process.sleep(100) && {:cont, value}
  end) == want || raise "#{key}: #{label} is not #{inspect(want)}"
end

# Back to the start page, Assigned to you: esc until it is there (a use case goes back to
# its scene, a scene to the scenes, the scenes to the start).
to_start = fn t ->
  Enum.reduce_while(1..6, nil, fn _, _ ->
    if settled(t) =~ ~r/Atlas · test.*\sAssigned to you$/m do
      {:halt, :ok}
    else
      press(t, "Escape")
      Process.sleep(700)
      {:cont, nil}
    end
  end)

  see(t, ~r/Atlas · test.*\sAssigned to you$/m)
end

scenario "UC-Atlas-29: Test a use case from My work: accept or reject", fn %{t1: t1, instance: i} ->
  step "Two use cases whose issues are all done are Melle's to test", fn ->
    atlas_json(i, ["put", "agent", "--name", "Coordinator"])
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene to answer in"])

    made =
      for {title, n} <- [{"A use case to reject", 2901}, {"A use case to accept", 2902}] do
        url = "https://github.com/eyra/atlas-e2e/pull/#{n}"
        {use_case, _} = atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", title])

        {issue, _} =
          atlas_json(i, ["put", "issue", "--in", use_case["key"], "--title", "Its issue"])

        pull = %{"title" => "Its issue", "state" => "open", "merged" => false, "html_url" => url}
        GitHub.put(url, pull)
        {pr, _} = atlas_json(i, ["put", "pull_request", "--url", url, "--in", issue["key"]])
        GitHub.put(url, %{pull | "state" => "closed", "merged" => true})
        {use_case["key"], [pr["key"], issue["key"]]}
      end

    Process.sleep(connector_wait)
    for {use_case, _} <- made, do: shows.(i, use_case, "Expected", "Test it")
    Process.put(:uc29, %{scene: scene["key"], made: made})
  end

  step "Reject, from My work: a note only; back to the coordinator with it", fn ->
    %{made: [{use_case, _}, _]} = Process.get(:uc29)
    # Room for a use case's three parts: what to do, its content and its references.
    resize(t1, 100, 40)
    to_start.(t1)
    open_row(t1, "A use case to reject")
    see(t1, "Use case #{use_case}: A use case to reject")
    # The answers, in the footer, from the flow definition.
    see(t1, "f Reject")
    see(t1, "a Accept")
    press(t1, "f")
    see(t1, "Reject #{use_case}")
    type(t1, "The footer is wrong")
    at = press(t1, "C-s")
    stored(t1, "Use case #{use_case}: A use case to reject", at)
    shows.(i, use_case, "Expected", "Rework: The footer is wrong")
    shows.(i, use_case, "Assigned to", "coordinator")
    # No longer Melle's: no answers for him on it now.
    gone(t1, "f Reject")
  end

  step "Accept, from My work: done, and it leaves My work", fn ->
    %{made: [{rejected, _}, {use_case, _}]} = Process.get(:uc29)
    to_start.(t1)
    refute_see(t1, "A use case to reject")
    open_row(t1, "A use case to accept")
    see(t1, "Use case #{use_case}: A use case to accept")
    press(t1, "a")
    see(t1, "will be accepted by melle")
    at = press(t1, "y")
    stored(t1, ~r/Accepted by ─+(.|\n)*melle  Person/, at)

    {got, _} = atlas_json(i, ["get", use_case])
    progress = Enum.find_value(got["fields"], fn [l, v] -> l == "Progress" && v end)
    progress =~ "Done" || raise inspect(got["fields"])

    to_start.(t1)
    gone(t1, "A use case to accept")
    refute_see(t1, rejected)
    resize(t1, 100, 30)
  end

  # The scenes list stays short enough for the scenarios after this one.
  step "Clean up: delete what this scenario made", fn ->
    %{scene: scene, made: made} = Process.get(:uc29)
    home(t1)

    for {use_case, under} <- made,
        key <- under ++ [use_case],
        do: {_, 0, _} = atlas(i, ["delete", key])

    {_, 0, _} = atlas(i, ["delete", scene])
    gone(t1, "A scene to answer in")
  end
end
