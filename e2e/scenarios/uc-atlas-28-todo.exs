# UC-Atlas-28, IS-Atlas-54: What to do, the owner's part of a fact's page. For its owner
# only, above the rest: what is expected, why it came to them, the instructions of the
# state it is in, the section of the fact the state names ("Melle can test") and the
# answers with their keys. `atlas get` shows the same part to a client that is the owner
# (an agent says which with ATLAS_AS). All words are the flow definition's and the fact's.
import AtlasE2E.Scenario

alias AtlasE2E.GitHub

url = "https://github.com/eyra/atlas-e2e/pull/2801"
# A connector's change shows by its hint, at most one round (2 s) after GitHub changed.
connector_wait = 5_000

description = """
What it is about.

Melle can test: open it from My work, and read this line.
"""

# `atlas get`'s answer for `key`, once `ok?` holds (Flow writes within moments).
got = fn i, key, ok? ->
  Enum.reduce_while(1..50, nil, fn _, _ ->
    {got, _} = atlas_json(i, ["get", key])
    if ok?.(got), do: {:halt, got}, else: Process.sleep(100) && {:cont, nil}
  end) || raise "#{key} never got there"
end

scenario "UC-Atlas-28: What to do, for the owner of a fact", fn %{t1: t1, instance: i} ->
  step "A use case whose issues are all done is Melle's to test", fn ->
    atlas_json(i, ["put", "agent", "--name", "Coordinator"])
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene with a test"])

    {use_case, _} =
      atlas_json(
        i,
        [
          "put",
          "use_case",
          "--in",
          scene["key"],
          "--title",
          "A use case to test",
          "--description",
          "-"
        ],
        0,
        description
      )

    {issue, _} = atlas_json(i, ["put", "issue", "--in", use_case["key"], "--title", "Its issue"])
    pull = %{"title" => "Its issue", "state" => "open", "merged" => false, "html_url" => url}
    GitHub.put(url, pull)
    {pr, _} = atlas_json(i, ["put", "pull_request", "--url", url, "--in", issue["key"]])
    GitHub.put(url, %{pull | "state" => "closed", "merged" => true})

    Process.sleep(connector_wait)
    got.(i, use_case["key"], &(["Expected", "Test it"] in &1["fields"]))

    Process.put(:uc28todo, %{
      scene: scene["key"],
      use_case: use_case["key"],
      issue: issue["key"],
      pr: pr["key"]
    })
  end

  step "Its page shows Melle what to do first: why, how, the test, and the answer", fn ->
    %{use_case: use_case} = Process.get(:uc28todo)
    # Room for its three parts: what to do, its content and its references.
    resize(t1, 100, 40)
    # From My work, the start page (home() goes on to the scenes; esc comes back).
    press(t1, "Escape")
    see(t1, ~r/Atlas · test.*\sAssigned to you$/m)
    open_row(t1, "A use case to test")
    see(t1, "Use case #{use_case}: A use case to test")
    see(t1, "What to do: Test it")
    see(t1, ~r/Why\s+Flow test_and_accept: all under it is completed → melle/)
    see(t1, ~r/How\s+Try the test below, then accept it, or reject it with a note\./)
    see(t1, ~r/Melle can test\s+open it from My work, and read this line\./)
    see(t1, ~r/Answers\s+a Accept/)
    see(t1, "a Accept")
    resize(t1, 100, 30)
  end

  step "atlas get shows the same part to its owner, and to nobody else", fn ->
    %{use_case: use_case, scene: scene} = Process.get(:uc28todo)
    # An agent on the command line is not melle: no part.
    {plain_get, _} = atlas_json(i, ["get", use_case])
    Map.has_key?(plain_get, "todo") && raise inspect(plain_get["todo"])

    # The coordinator owns an open issue; as the coordinator, atlas get shows its part.
    {other, _} = atlas_json(i, ["put", "use_case", "--in", scene, "--title", "Still building"])
    {open, _} = atlas_json(i, ["put", "issue", "--in", other["key"], "--title", "To build"])
    as_coordinator = %{i | env: [{"ATLAS_AS", "coordinator"} | i.env]}
    got.(as_coordinator, open["key"], &(&1["todo"] != nil))

    {text, 0, _} = atlas(as_coordinator, ["get", open["key"]])
    text =~ ~r/^What to do: Build it$/m || raise text
    text =~ "How: Build it in one pull request and get that merged" || raise text
    {plain, 0, _} = atlas(i, ["get", open["key"]])
    plain =~ "What to do" && raise plain

    Process.put(:uc28todo_more, [open["key"], other["key"]])
  end

  # The scenes list stays short enough for the scenarios after this one.
  step "Clean up: delete what this scenario made", fn ->
    %{scene: scene, use_case: use_case, issue: issue, pr: pr} = Process.get(:uc28todo)
    home(t1)

    for key <- [pr, issue] ++ Process.get(:uc28todo_more) ++ [use_case, scene],
        do: {_, 0, _} = atlas(i, ["delete", key])

    gone(t1, "A scene with a test")
  end
end
