# UC-Atlas-28: My work on the front page. IS-Atlas-55: the TUI's user is a person, so
# Control opens on what is assigned to them (start.assigned in rela/atlas.json): their
# Assignments (IS-Atlas-78), each as the open fact it belongs to, newest move first, with
# what its flow expects and since when and why; the header counts them on every page; a
# hint updates it in every TUI. The scenes are one key away (s).
import AtlasE2E.Scenario

scenario "UC-Atlas-28: My work on the front page", fn %{t1: t1, t2: t2, instance: i} ->
  row = fn key, title -> ~r/#{key}\s+#{Regex.escape(title)}/ end

  # Back to the start page. A TUI learns that its user is a person when it reconciles
  # (every 5 seconds); until then the scenes are its start page and there is no way back.
  start_page = fn t ->
    Enum.reduce_while(1..12, nil, fn _, _ ->
      screen = AtlasE2E.Tui.screen(t)

      if screen =~ ~r/Atlas · test.*\sAssigned to you$/m do
        {:halt, screen}
      else
        if screen =~ "esc back", do: press(t, "Escape")
        Process.sleep(1_000)
        {:cont, nil}
      end
    end)
    |> case do
      nil -> see(t, ~r/Atlas · test.*\sAssigned to you$/m)
      screen -> screen
    end
  end

  step "The TUI's user is a person: the start page is what is assigned to them", fn ->
    # UC-Atlas-32 makes melle too: the same name is the same key.
    atlas(i, ["put", "person", "--name", "Melle"])
    atlas(i, ["put", "agent", "--name", "Coordinator"])

    for t <- [t1, t2] do
      start_page.(t)
      see(t, "Nothing is assigned to you now.")
      see(t, "s opens the scenes.")
      see(t, ~r/Atlas · test · 0 assigned to you/)
      see(t, "s Scenes")
    end
  end

  step "A fact assigned to you shows in both TUIs by hint, with why; the header counts it", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene for you"])

    {use_case, _} =
      atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "A use case for you"])

    Process.put(:uc28, %{scene: scene["key"], use_case: use_case["key"]})

    {_, at} =
      atlas_json(i, [
        "set",
        use_case["key"],
        "assigned_to=melle",
        "--cause",
        "all its issues are completed"
      ])

    for t <- [t1, t2], do: by_hint(t, row.(use_case["key"], "A use case for you"), at)
    see(t1, ~r/since \d+ \w+ \d\d:\d\d · all its issues are completed/)
    see(t1, ~r/Atlas · test · 1 assigned to you/)
    # What its flow expects, once Flow has written it.
    see(t1, ~r/Build it · since/, 10_000)
  end

  step "Newest move first", fn ->
    %{scene: scene, use_case: use_case} = Process.get(:uc28)

    {_, at} =
      atlas_json(i, ["set", scene, "assigned_to=melle", "--cause", "a second one for you"])

    screen = by_hint(t1, row.(scene, "A scene for you"), at)
    {first, _} = :binary.match(screen, scene)
    {second, _} = :binary.match(screen, use_case)
    first < second || raise "not newest first:\n#{screen}"
    see(t1, ~r/Atlas · test · 2 assigned to you/)
  end

  step "Moved away: gone by hint in both TUIs, and the count goes down", fn ->
    %{use_case: use_case} = Process.get(:uc28)

    {_, at} =
      atlas_json(i, ["set", use_case, "assigned_to=coordinator", "--cause", "back to building"])

    for t <- [t1, t2], do: by_hint(t, row.(use_case, "A use case for you"), at, gone: true)
    see(t1, ~r/Atlas · test · 1 assigned to you/)
  end

  step "s opens the scenes, with the count; esc comes back; enter opens a fact", fn ->
    %{scene: scene} = Process.get(:uc28)
    press(t1, "s")
    see(t1, ~r/Atlas · test · 1 assigned to you.*\sScenes$/m)
    press(t1, "Escape")
    see(t1, ~r/Atlas · test.*\sAssigned to you$/m)
    open_row(t1, "A scene for you")
    see(t1, "Scene #{scene}: A scene for you")
  end

  # IS-Atlas-78: what is assigned is an Assignment; the list shows the fact it belongs to,
  # while that fact is open.
  step "Done: an accepted use case leaves the list; its Assignment still names you", fn ->
    %{scene: scene} = Process.get(:uc28)

    {done, _} =
      atlas_json(i, ["put", "use_case", "--in", scene, "--title", "A use case to accept"])

    atlas_json(i, ["set", done["key"], "assigned_to=melle", "--cause", "ready to accept"])
    start_page.(t1)
    see(t1, ~r/Atlas · test · 2 assigned to you/)
    open_row(t1, "A use case to accept")
    see(t1, "Use case #{done["key"]}: A use case to accept")
    press(t1, "a")
    see(t1, "will be accepted by melle")
    at = press(t1, "y")
    stored(t1, ~r/Accepted by ─+(.|\n)*melle  Person/, at)

    start_page.(t1)
    see(t1, ~r/Atlas · test · 1 assigned to you/)
    refute_see(t1, "A use case to accept")

    {part, _} = atlas_json(i, ["get", "AS-" <> done["key"]])
    ["Assigned to", "melle"] in part["fields"] || raise inspect(part["fields"])
  end
end
