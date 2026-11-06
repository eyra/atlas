# UC-Atlas-31, IS-Atlas-61: an issue shows Development while its pull request is open,
# worked out by State and set by nobody; Done once it is merged; a closed, unmerged pull
# request no longer counts. GitHub is the stand-in, read every 2 seconds.
import AtlasE2E.Scenario

alias AtlasE2E.GitHub

url = "https://github.com/eyra/atlas-e2e/pull/3101"
# A connector's change shows by its hint, at most one round (2 s) after GitHub changed.
connector_wait = 5_000

scenario "UC-Atlas-31: An issue shows Development while its pull request is open", fn ctx ->
  %{t1: t1, instance: i} = ctx

  step "An issue at specification, open in TUI 1", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene whose issue gets a PR"])
    {use_case, _} = atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "Its UC"])

    {issue, _} =
      atlas_json(i, ["put", "issue", "--in", use_case["key"], "--title", "An issue at spec"])

    open_row(t1, "A scene whose issue gets a PR")
    open_row(t1, "Its UC")
    see(t1, ~r/#{issue["key"]}\s+An issue at spec[\s│]+Specification/)
    Process.put(:uc31, issue["key"])
    Process.put(:uc31_made, [issue["key"], use_case["key"], scene["key"]])
  end

  step "A pull request is linked and open: Development, without anyone setting it", fn ->
    issue = Process.get(:uc31)

    pull = %{
      "title" => "An issue at spec",
      "state" => "open",
      "merged" => false,
      "html_url" => url
    }

    GitHub.put(url, pull)
    {_, at} = atlas_json(i, ["put", "pull_request", "--url", url, "--in", issue])
    by_hint(t1, "Development", at)

    {got, _} = atlas_json(i, ["get", issue])
    progress = Enum.find_value(got["fields"], fn [l, v] -> l == "Progress" && v end)
    progress == "Development · PR-eyra-atlas-e2e-3101 open" || raise inspect(got["fields"])
    got["values"]["stage"] == "specification" || raise inspect(got["values"])
  end

  step "Closed without merging: it counts no more; the stored stage shows again", fn ->
    issue = Process.get(:uc31)

    GitHub.put(url, %{
      "title" => "An issue at spec",
      "state" => "closed",
      "merged" => false,
      "html_url" => url
    })

    see(t1, ~r/#{issue}\s+An issue at spec[\s│]+Specification/, connector_wait)
  end

  # The scenes list stays short enough for the scenarios after this one.
  step "Clean up: delete what this scenario made", fn ->
    home(t1)
    {_, 0, _} = atlas(i, ["delete", "PR-eyra-atlas-e2e-3101"])
    for key <- Process.get(:uc31_made), do: {_, 0, _} = atlas(i, ["delete", key])
    gone(t1, "A scene whose issue gets a PR")
  end
end
