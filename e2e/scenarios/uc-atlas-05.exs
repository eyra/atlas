# UC-Atlas-05: move the plan into Atlas (`atlas load-plan`), on an instance that already
# holds items, so the codes of the file are taken and the loader maps them.
import AtlasE2E.Scenario

scenario "UC-Atlas-05: Move the plan into Atlas", fn %{t2: t2, instance: i} ->
  scenes = Path.join(i.root, "e2e/fixtures/scenes.md")
  links = Path.join(i.dir, "links.json")

  File.write!(
    links,
    JSON.encode!(%{
      "pull_requests" => [
        %{"url" => "https://github.com/eyra/atlas-e2e/pull/501", "issue" => "IS-01"}
      ],
      "stages" => %{"IS-01" => "testing"}
    })
  )

  load = fn extra -> atlas(i, ["load-plan", scenes, links | extra]) end

  step "Something is there already: a scene made first takes the file's first code", fn ->
    {_, _} = atlas_json(i, ["put", "scene", "--title", "Made before the plan"])
  end

  step "A dry run: what it would create, and the mapping; nothing written", fn ->
    {before, _} = atlas_json(i, ["list", "scene"])
    {out, 0, _} = load.(["--dry-run"])
    out =~ "2 scenes, 2 use cases, 1 issues; 1 pull requests to link. To create: 5" || raise out

    (out =~ "Mapping (SCENES.md → Atlas), where they differ:" and
       out =~ ~r/^  SC-Atlas-01 → SC-Atlas-\d+$/m) ||
      raise out

    {after_dry, _} = atlas_json(i, ["list", "scene"])
    after_dry == before || raise "the dry run wrote something"
  end

  step "The run: every item under its parent, codes mapped; TUI 2 shows them by hint", fn ->
    {out, 0, at} = load.([])

    out =~ "Done: 5 created, 0 already there, 1 stages set, 1 of 1 pull requests linked." ||
      raise out

    by_hint(t2, "A loaded scene", at)
    see(t2, "A second loaded scene")

    [_, scene] = Regex.run(~r/created (SC-Atlas-\d+)  A loaded scene/, out)
    [_, second] = Regex.run(~r/created (SC-Atlas-\d+)  A second loaded scene/, out)
    [_, issue] = Regex.run(~r/created (IS-Atlas-\d+)  A loaded issue/, out)

    {got, _} = atlas_json(i, ["get", scene])

    got["values"]["description"] =~ "## User story\n\nAs the end-to-end test" ||
      raise inspect(got)

    [row] = hd(got["lists"])["rows"]
    row["label"] == "A loaded use case" || raise inspect(got["lists"])

    {got, _} = atlas_json(i, ["get", issue])
    got["values"]["description"] =~ "it names #{second} and" || raise inspect(got["values"])
    got["values"]["stage"] == "testing" || raise inspect(got["values"])

    hd(got["lists"])["rows"] |> hd() |> Map.fetch!("key") == "PR-eyra-atlas-e2e-501" ||
      raise inspect(got)
  end

  step "Run again: everything is there already; nothing is created", fn ->
    {out, 0, _} = load.([])
    out =~ "To create: 0; already there: 5." || raise out
    out =~ "Done: 0 created, 5 already there" || raise out
  end
end
