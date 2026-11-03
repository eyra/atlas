# UC-Atlas-21: find out what Atlas can do (README, "Driving Atlas from an agent").
import AtlasE2E.Scenario

scenario "UC-Atlas-21: Find out what Atlas can do", fn %{instance: instance} ->
  step "atlas help: the commands, then every kind from rela's description", fn ->
    {out, 0, _} = atlas(instance, ["help"])

    for text <- [
          "atlas put <kind>",
          "Kinds (from rela's description, through Control):",
          "Scene (scene)",
          "Use case (use_case)",
          "Belongs under: scene",
          "Create asks: title, description",
          "Id: made from url: PR-{1}-{2}-{3}"
        ],
        do: out =~ text || raise("atlas help does not say #{inspect(text)}:\n#{out}")
  end

  step "atlas put <kind> --help: that kind only; --json for an agent", fn ->
    {out, 0, _} = atlas(instance, ["put", "issue", "--help"])
    out =~ "Issue (issue)" || raise "no issue in:\n#{out}"
    out =~ "Belongs under: use_case" || raise "no parent in:\n#{out}"
    if out =~ "Scene (scene)", do: raise("put issue --help shows other kinds")

    {kinds, _} = atlas_json(instance, ["help"])
    names = Enum.map(kinds, & &1["kind"])
    (names == Enum.sort(names) && "scene" in names) || raise "kinds: #{inspect(names)}"
  end

  step "A kind Atlas does not have: the kinds it has, and a non-zero exit", fn ->
    {answer, _} = atlas_json(instance, ["help", "nothing"], 2)
    answer["error"] =~ "Atlas has no kind \"nothing\"; it has " || raise inspect(answer)
  end
end
