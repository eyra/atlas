# Runs after the shared ownership scenarios: creating their coordinator earlier changes
# their first-owner fixtures. This scenario uses its own stub, never a model.
import AtlasE2E.Scenario

wait_for = fn i, key, label, want ->
  Enum.reduce_while(1..80, nil, fn _, _ ->
    {out, status, _} = atlas(i, ["get", key, "--json"])
    got = if status == 0, do: JSON.decode!(out), else: %{}

    if [label, want] in (got["fields"] || []),
      do: {:halt, got},
      else:
        (
          Process.sleep(200)
          {:cont, nil}
        )
  end) || raise "#{key}: #{label} never became #{want}"
end

scenario "UC-Atlas-08: break down several children before the turn hands over", fn %{
                                                                                     instance: i,
                                                                                     t1: t1
                                                                                   } ->
  agent = %{i | env: [{"ATLAS_AS", "breaker"} | i.env]}

  step "The assigned stub reads its turn and the scene's instructions", fn ->
    atlas_json(i, ["put", "agent", "--name", "Coordinator"])
    atlas_json(i, ["put", "agent", "--name", "Breaker"])
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "Breakdown stays in one turn"])

    atlas_json(i, ["set", scene["key"], "assigned_to=breaker", "--cause", "break this scene down"])

    turn = "TU-AS-#{scene["key"]}-1"
    wait_for.(i, turn, "State", "Running")
    {context, _} = atlas_json(agent, ["turn"])
    context["key"] == turn || raise inspect(context)
    context["on"] == scene["key"] || raise "the turn did not resolve its original item"
    context["item"]["todo"] != nil || raise "the owner got no instructions"
    {text, 0, _} = atlas(agent, ["turn"])
    text =~ "Break it down into use cases and issues" || raise text
    Process.put(:uc08, %{scene: scene["key"], turn: turn, children: []})
  end

  step "The first child changes Expected; both children are made while the stub keeps its turn",
       fn ->
         %{scene: scene, turn: turn} = saved = Process.get(:uc08)

         children =
           for n <- 1..2 do
             {uc, _} =
               atlas_json(agent, [
                 "put",
                 "use_case",
                 "--in",
                 scene,
                 "--title",
                 "Breakdown part #{n}"
               ])

             {issue, _} =
               atlas_json(agent, [
                 "put",
                 "issue",
                 "--in",
                 uc["key"],
                 "--title",
                 "Build breakdown part #{n}"
               ])

             wait_for.(i, scene, "Expected", "Build it")
             wait_for.(i, scene, "Assigned to", "breaker")
             wait_for.(i, turn, "State", "Running")
             {context, _} = atlas_json(agent, ["turn"])
             context["key"] == turn || raise "breakdown left its turn early"
             {uc["key"], issue["key"]}
           end

         Process.put(:uc08, %{saved | children: children})
         home(t1)
         open_row(t1, "Breakdown stays in one turn")
         see(t1, "Breakdown part 1")
         see(t1, "Breakdown part 2")
       end

  step "The outcome is stored by the agent; Runtime ends it and Flow hands it over", fn ->
    %{scene: scene, turn: turn} = Process.get(:uc08)
    {outcome, _} = atlas_json(agent, ["turn", "end", "Created two use cases, each with an issue"])
    outcome["turn"] == turn || raise inspect(outcome)
    wait_for.(i, turn, "State", "Ended")

    wait_for.(
      i,
      turn,
      "Why",
      "the agent ended its turn: Created two use cases, each with an issue"
    )

    wait_for.(i, scene, "Assigned to", "coordinator")
    # IS-Atlas-123: a replacement must never race the durable deferred handover.
    {_, replacement_status, _} = atlas(i, ["get", "TU-AS-#{scene}-2", "--json"])
    replacement_status != 0 || raise "the old owner got a replacement before handover"
    {_, status, _} = atlas(agent, ["turn", "--json"])
    status != 0 || raise "the old agent still has a current turn"
  end

  step "A human handover cancels a later turn and its deferred automatic handover", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "Cancel breakdown by hand"])

    atlas_json(i, [
      "set",
      scene["key"],
      "assigned_to=breaker",
      "--cause",
      "try a second breakdown"
    ])

    turn = "TU-AS-#{scene["key"]}-1"
    wait_for.(i, turn, "State", "Running")

    {uc, _} =
      atlas_json(agent, [
        "put",
        "use_case",
        "--in",
        scene["key"],
        "--title",
        "Cancelled breakdown child"
      ])

    wait_for.(i, scene["key"], "Expected", "Build it")
    wait_for.(i, scene["key"], "Assigned to", "breaker")
    human = %{i | env: [{"ATLAS_AS", "melle"} | i.env]}
    atlas_json(human, ["set", scene["key"], "assigned_to=melle", "--cause", "stop this turn"])
    wait_for.(i, turn, "State", "Ended")
    wait_for.(i, scene["key"], "Assigned to", "melle")
    {_, status, _} = atlas(agent, ["turn", "end", "too late", "--json"])
    status != 0 || raise "cancelled agent could still end a turn"
    AtlasE2E.Instance.cleanup_turn_fixtures(i, [turn])
    for key <- [uc["key"], scene["key"]], do: atlas_json(i, ["delete", key])
  end

  step "Clean up this scenario's plan", fn ->
    %{scene: scene, turn: turn, children: children} = Process.get(:uc08)
    home(t1)

    for {uc, issue} <- children do
      atlas_json(i, ["delete", issue])
      atlas_json(i, ["delete", uc])
    end

    AtlasE2E.Instance.cleanup_turn_fixtures(i, [turn])
    atlas_json(i, ["delete", scene])
    gone(t1, "Breakdown stays in one turn")
  end
end
