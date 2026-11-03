# UC-Atlas-27, IS-Atlas-88: a done fact has no owner (IS-Atlas-75's rule). Facts that
# were done before Flow wrote owners kept the coordinator the IS-Atlas-52 migration gave
# them; `atlas migrate-done-owner` removes an owner a migration set from a fact Flow
# expects nothing of, never one set by hand or by Flow. A rerun has nothing to do.
import AtlasE2E.Scenario

alias AtlasE2E.GitHub

url = "https://github.com/eyra/atlas-e2e/pull/8801"

# What `atlas get` shows for `label`, once it is `want` (Flow and the connector write
# within moments).
shows = fn i, key, label, want ->
  Enum.reduce_while(1..60, nil, fn _, _ ->
    {got, _} = atlas_json(i, ["get", key])
    value = Enum.find_value(got["fields"], fn [l, v] -> l == label && v end)

    if value == want,
      do: {:halt, got},
      else: Process.sleep(100) && {:cont, got}
  end)
  |> tap(fn got ->
    [label, want] in got["fields"] || want == nil || raise "#{key}: #{inspect(got["fields"])}"
  end)
end

scenario "UC-Atlas-27: A done fact has no owner", fn %{instance: i} ->
  step "A merged pull request and its issue are done: Flow leaves them nobody", fn ->
    # The same name is the same key: an earlier scenario may have made the coordinator.
    atlas(i, ["put", "agent", "--name", "Coordinator"])
    {issue, _} = atlas_json(i, ["put", "issue", "--title", "An issue done before Flow"])
    shows.(i, issue["key"], "Assigned to", "coordinator")

    pull = %{"title" => "Done before", "state" => "open", "merged" => false, "html_url" => url}
    GitHub.put(url, pull)
    {pr, _} = atlas_json(i, ["put", "pull_request", "--url", url, "--in", issue["key"]])
    GitHub.put(url, %{pull | "state" => "closed", "merged" => true})

    shows.(i, issue["key"], "Assigned to", "—")
    shows.(i, pr["key"], "Assigned to", "—")
    Process.put(:uc27done, %{issue: issue["key"], pr: pr["key"]})
  end

  step "The issue gets the coordinator from a migration, the pull request from a user", fn ->
    %{issue: issue, pr: pr} = Process.get(:uc27done)
    atlas_json(i, ["set", pr, "assigned_to=coordinator", "--cause", "kept on purpose"])
    {out, 0, _} = atlas(i, ["migrate-owner"])
    out =~ "assign   AS-#{issue}  assigned_to coordinator" || raise out
    String.contains?(out, "AS-#{pr} ") && raise "the migration moved a hand-set owner:\n" <> out

    got = shows.(i, issue, "Assigned to", "coordinator")
    got["origins"]["Assigned to"]["by"] == "migration" || raise inspect(got["origins"])
  end

  step "atlas migrate-done-owner: the migration's owner goes, the user's stays; a rerun has 0",
       fn ->
         %{issue: issue, pr: pr} = Process.get(:uc27done)

         {dry, 0, _} = atlas(i, ["migrate-done-owner", "--dry-run"])
         dry =~ "unassign AS-#{issue}  assigned_to coordinator  (#{issue} is done)" || raise dry
         String.contains?(dry, "AS-#{pr} ") && raise "it would remove a hand-set owner:\n" <> dry
         dry =~ "Dry run: nothing was written." || raise dry

         {out, 0, _} = atlas(i, ["migrate-done-owner"])
         out =~ ~r/Done: (\d+) of \1 steps written\./ || raise out

         got = shows.(i, issue, "Assigned to", "—")
         origin = got["origins"]["Assigned to"]
         origin["cause"] == "done: no owner (IS-Atlas-75's rule)" || raise inspect(origin)
         shows.(i, pr, "Assigned to", "coordinator")

         {again, 0, _} = atlas(i, ["migrate-done-owner", "--dry-run"])
         again =~ "IS-Atlas-88 one-off: 0 steps" || raise again
       end
end
