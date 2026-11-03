# UC-Atlas-19: see and overrule what the agent did (docs/guides/uc-atlas-19.md). Each
# request, its steps and its outcome are facts in State; the start page has `w What the
# agent did`; x Overrule on a stored step proposes the steps that undo it.
import AtlasE2E.Scenario

scenario "UC-Atlas-19: See and overrule what the agent did", fn %{t1: t1, t2: t2, instance: i} ->
  description = """
  Melle looks back at what the agent did.

  - Keep what the agent did
  - Drop this one
  """

  row = fn title -> ~r/UC-Atlas-\d+\s+#{Regex.escape(title)}/ end

  step "A request whose plan runs: one step kept, one dropped", fn ->
    for t <- [t1, t2], do: see(t, ~r/Atlas · test\s+Scenes$/m)

    {scene, at} =
      atlas_json(
        i,
        ["put", "scene", "--title", "A scene to look back on", "--description", "-"],
        0,
        description
      )

    Process.put(:scene, scene["key"])
    by_hint(t1, "A scene to look back on", at)
    open_row(t1, "A scene to look back on")
    see(t1, "No use cases yet.")
    press(t1, ":")
    type(t1, "propose use cases from this scene's description")
    press(t1, "Enter")
    see(t1, "Proposed: 2 steps", 10_000)
    press(t1, ["Down", "Space"])
    see(t1, "[ ] 2. Create use case in")
    press(t1, "Enter")
    see(t1, "Done: 1 of 1 stored", 10_000)
    press(t1, "Enter")
    see(t1, row.("Keep what the agent did"))
  end

  step "The record: the request, its outcome and each step, as facts", fn ->
    # Earlier scenarios asked too: this one's is the newest.
    {requests, _} = atlas_json(i, ["list", "agent_request"])
    request = Enum.max_by(requests, & &1["key"])
    Process.put(:request, request["key"])

    request["label"] == "propose use cases from this scene's description" ||
      raise inspect(request)

    {got, _} = atlas_json(i, ["get", request["key"]])
    got["values"]["outcome"] == "done" || raise inspect(got["values"])
    got["values"]["planner"] == "the e2e stand-in" || raise inspect(got["values"])
    got["values"]["page"] == "/k/scene/#{Process.get(:scene)}" || raise inspect(got["values"])

    [stored, dropped] = hd(got["lists"])["rows"] |> Enum.sort_by(& &1["key"])
    {step, _} = atlas_json(i, ["get", stored["key"]])
    step["values"]["state"] == "stored" || raise inspect(step["values"])
    step["values"]["made"] =~ ~r/^UC-Atlas-\d+$/ || raise inspect(step["values"])
    step["values"]["values"] =~ ~s|"title":"Keep what the agent did"| || raise inspect(step)
    Process.put(:step, stored["key"])
    Process.put(:made, step["values"]["made"])

    Process.put(:dropped, dropped["key"])
    {step, _} = atlas_json(i, ["get", dropped["key"]])
    step["values"]["state"] == "dropped" || raise inspect(step["values"])
    step["values"]["made"] == "" || raise inspect(step["values"])
  end

  step "The start page has `w What the agent did`; the request shows with its steps", fn ->
    request = Process.get(:request)
    home(t1)
    see(t1, "w What the agent did")
    refute_see(t1, "Agent requests")
    press(t1, "w")
    see(t1, ~r/Atlas · test\s+Agent requests$/m)
    see(t1, ~r/#{request}\s+propose use cases from this scene's description\s+Done/)
    open_row(t1, "propose use cases from this scene's description")
    see(t1, "Agent request #{request}: propose use cases")
    see(t1, ~r/Outcome\s+Done/)
    see(t1, ~r/Planner\s+the e2e stand-in/)
    see(t1, "Steps")
    see(t1, Process.get(:step))
    # Only the agent writes the record: no keys to create, update or delete it.
    refute_see(t1, ~r/\bu Update|\bd Delete|\bc Create/)
  end

  step "From the use case the agent made, its step: what the agent did here", fn ->
    home(t1)
    open_row(t1, "A scene to look back on")
    see(t1, row.("Keep what the agent did"))
    open_row(t1, "Keep what the agent did")
    see(t1, "Use case #{Process.get(:made)}: Keep what the agent did")
    see(t1, "What the agent did here")
    see(t1, "Create use case in #{Process.get(:scene)}")
  end

  step "A cancelled request is kept too, and comes first: newest first", fn ->
    home(t1)
    open_row(t1, "A scene to look back on")
    see(t1, "Scene #{Process.get(:scene)}: A scene to look back on")
    press(t1, ":")
    type(t1, "propose use cases from this scene's description")
    press(t1, "Enter")
    see(t1, "Proposed: 2 steps", 10_000)
    press(t1, "Escape")
    gone(t1, "space keep/drop")
    {requests, _} = atlas_json(i, ["list", "agent_request"])
    [newest, oldest | _] = Enum.sort_by(requests, & &1["key"], :desc)
    oldest["key"] == Process.get(:request) || raise inspect(requests)
    {got, _} = atlas_json(i, ["get", newest["key"]])
    got["values"]["outcome"] == "cancelled" || raise inspect(got["values"])

    home(t1)
    press(t1, "w")
    screen = see(t1, ~r/Atlas · test\s+Agent requests$/m)
    {a, _} = :binary.match(screen, newest["key"])
    {b, _} = :binary.match(screen, oldest["key"])
    a < b || raise "not newest first:\n#{screen}"
  end

  # The page of one of the agent's steps, from the start page.
  open_step = fn request, step ->
    home(t1)
    press(t1, "w")
    see(t1, ~r/Atlas · test\s+Agent requests$/m)
    open_row(t1, request)
    see(t1, "Agent request #{request}:")
    open_row(t1, step)
    see(t1, "Agent step #{step}:")
  end

  step "x Overrule on a stored step: the steps that undo it, asked first; enter deletes", fn ->
    {request, made, scene} = {Process.get(:request), Process.get(:made), Process.get(:scene)}

    # TUI 2 on the scene, to see the use case go.
    home(t2)
    open_row(t2, "A scene to look back on")
    see(t2, row.("Keep what the agent did"))

    # A dropped step stored nothing: no x.
    open_step.(request, Process.get(:dropped))
    refute_see(t1, "x Overrule")

    open_step.(request, Process.get(:step))
    see(t1, "x Overrule")
    press(t1, "x")
    see(t1, "Proposed: 1 step", 10_000)
    see(t1, ~r/You asked\s+Overrule #{Process.get(:step)}: 1\. Create use case in #{scene}/)
    see(t1, "By              Atlas, from the record of #{Process.get(:step)}")
    see(t1, "[✓] 1. Delete use case #{made}?")
    at = press(t1, "Enter")
    by_hint(t2, row.("Keep what the agent did"), at, gone: true)
    see(t1, "Done: 1 of 1 stored", 10_000)
    refute_see(t1, "without asking")
    see(t1, "Deleted #{made}.")

    # The request it overrules lists it; the overrule is a request of its own.
    {requests, _} = atlas_json(i, ["list", "agent_request"])
    overrule = Enum.max_by(requests, & &1["key"])
    {got, _} = atlas_json(i, ["get", overrule["key"]])
    got["values"]["overrules"] == request || raise inspect(got["values"])
    got["values"]["outcome"] == "done" || raise inspect(got["values"])

    press(t1, "Enter")
    press(t1, "Escape")
    see(t1, "Agent request #{request}:")
    see(t1, "Overruled by")
    see(t1, overrule["key"])
  end

  step "Overruling a change puts back the values it replaced", fn ->
    scene = Process.get(:scene)
    home(t1)
    open_row(t1, "A scene to look back on")
    see(t1, "Scene #{scene}: A scene to look back on")
    press(t1, ":")
    type(t1, "rename to A renamed look back")
    press(t1, "Enter")
    see(t1, "Done: 1 of 1 stored, without asking", 10_000)
    press(t1, "Enter")
    see(t1, "Scene #{scene}: A renamed look back")

    {requests, _} = atlas_json(i, ["list", "agent_request"])
    rename = Enum.max_by(requests, & &1["key"])
    {got, _} = atlas_json(i, ["get", rename["key"]])
    [set] = hd(got["lists"])["rows"]

    open_step.(rename["key"], set["key"])
    press(t1, "x")
    see(t1, "Proposed: 1 step", 10_000)
    see(t1, "[✓] 1. Update #{scene}")
    see(t1, "A scene to look back on")
    press(t1, "Enter")
    see(t1, "Done: 1 of 1 stored", 10_000)

    {scene_now, _} = atlas_json(i, ["get", scene])
    scene_now["values"]["title"] == "A scene to look back on" || raise inspect(scene_now)
  end
end
