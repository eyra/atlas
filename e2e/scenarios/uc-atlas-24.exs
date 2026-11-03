# UC-Atlas-24: link a pull request and follow its issue, with a TUI open on the issue.
import AtlasE2E.Scenario

scenario "UC-Atlas-24: Link a pull request and follow its issue", fn %{t1: t1, instance: i} ->
  url = "https://github.com/eyra/atlas-e2e/pull/2401"

  step "An issue made from the command line; TUI 1 opens it", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene with a merged issue"])

    {use_case, _} =
      atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "Its use case"])

    {issue, _} =
      atlas_json(i, [
        "put",
        "issue",
        "--in",
        use_case["key"],
        "--title",
        "An issue that gets merged"
      ])

    open_row(t1, "A scene with a merged issue")
    open_row(t1, "Its use case")
    open_row(t1, "An issue that gets merged")
    see(t1, "Issue #{issue["key"]}: An issue that gets merged")
    Process.put(:uc24, issue["key"])
  end

  step "atlas put pull_request --url --in: its id from the URL; TUI 1 shows it by hint", fn ->
    issue = Process.get(:uc24)
    {pr, at} = atlas_json(i, ["put", "pull_request", "--url", url, "--in", issue])
    pr["key"] == "PR-eyra-atlas-e2e-2401" || raise inspect(pr)
    by_hint(t1, pr["key"], at)

    # The same URL from the same issue again is the same pull request.
    {again, _} = atlas_json(i, ["put", "pull_request", "--url", url, "--in", issue])
    again["key"] == pr["key"] || raise inspect(again)
  end

  step "atlas set stage=development: TUI 1 shows the new stage by hint", fn ->
    issue = Process.get(:uc24)
    {_, at} = atlas_json(i, ["set", issue, "stage=development"])
    by_hint(t1, ~r/Stage\s+Development/, at)
  end
end
