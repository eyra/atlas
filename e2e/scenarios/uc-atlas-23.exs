# UC-Atlas-23: read items from the command line.
import AtlasE2E.Scenario

scenario "UC-Atlas-23: Read items from the command line", fn %{instance: i} ->
  step "atlas get: the item and what hangs under it, as text and as JSON", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene to read"])
    key = scene["key"]
    text = "Two lines\nof text"

    {use_case, _} =
      atlas_json(i, [
        "put",
        "use_case",
        "--in",
        key,
        "--title",
        "A use case to read",
        "--description",
        text
      ])

    {out, 0, _} = atlas(i, ["get", key])

    for line <- [
          "Scene #{key}: A scene to read",
          "Use cases:",
          "#{use_case["key"]}  A use case to read"
        ],
        do: out =~ line || raise("atlas get does not show #{inspect(line)}:\n#{out}")

    {got, _} = atlas_json(i, ["get", use_case["key"]])
    got["values"]["description"] == text || raise inspect(got)
    Process.put(:uc23, {key, use_case["key"]})
  end

  step "atlas list, and list --in: the rows the TUI shows", fn ->
    {scene, use_case} = Process.get(:uc23)
    {rows, _} = atlas_json(i, ["list", "scene"])

    Enum.any?(rows, &(&1["key"] == scene and &1["label"] == "A scene to read")) ||
      raise inspect(rows)

    {rows, _} = atlas_json(i, ["list", "use_case", "--in", scene])
    Enum.map(rows, & &1["key"]) == [use_case] || raise inspect(rows)

    {out, 0, _} = atlas(i, ["list", "use_case", "--in", scene])
    out == "#{use_case}  A use case to read\n" || raise inspect(out)
  end

  step "A code Atlas does not have: exit 2, and why", fn ->
    {answer, _} = atlas_json(i, ["get", "SC-Atlas-99"], 2)
    answer["error"] =~ "SC-Atlas-99" || raise inspect(answer)
  end
end
