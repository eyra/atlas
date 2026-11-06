# UC-Atlas-20: long titles and descriptions (docs/guides/uc-atlas-20.md).
import AtlasE2E.Scenario

title =
  "Melle writes a scene with a title longer than the field, so that it has to wrap onto a second row"

scenario "UC-Atlas-20: Write long titles and descriptions", fn %{
                                                                 t1: t1,
                                                                 t2: t2,
                                                                 instance: instance
                                                               } ->
  step "A long title wraps in its field", fn ->
    # A scene's page holds its references too (its Assignment, IS-Atlas-78): a window
    # with the room it had before that (4 rows more), so the description still folds.
    resize(t1, 100, 34)
    press(t1, "c")
    see(t1, ~r/^ Create scene$/m)
    type(t1, title)
    # The end of the title is on a second row of the field, nothing is cut.
    see(t1, ~r/\n\s+\[.*onto a second row▏/)
  end

  step "A description of several sections: enter starts a new line", fn ->
    press(t1, "Down")
    see(t1, "Description")
    type(t1, "## Why")
    press(t1, ["Enter", "Enter"])
    type(t1, "Because a scene tells a story, and a story takes more than one line.")
    press(t1, ["Enter", "Enter"])
    type(t1, "## What")
    press(t1, "Enter")
    type(t1, "- the title wraps")
    press(t1, "Enter")
    type(t1, "- the description keeps its lines")
    press(t1, ["Enter", "Enter"])
    type(t1, "## Done when")
    press(t1, "Enter")
    type(t1, "1. it is stored and shown as written")
    see(t1, ~r/\[- the description keeps its lines\s+\]/)
  end

  step "Save: the page shows the lines, blank lines and sections; TUI 2 by hint", fn ->
    at = press(t1, "C-s")
    stored(t1, ~r/✓ Stored as SC-Atlas-\d+/, at)
    stored(t1, ~r/Description\s+## Why[\s│]*\n[\s│]*\n[\s│]+Because a scene/u, at)
    by_hint(t2, "Melle writes a scene with a title longer", at)
    Process.put(:scene, capture(t1, ~r/Scene (SC-Atlas-\d+):/))

    # The description is longer than its part: the part says so, and the list of use
    # cases stays in view (IS-Atlas-48). ] selects the content pane; PageDown
    # scrolls that pane without selecting a row or changing tabs.
    see(t1, ~r/… \d+ more lines?/)
    see(t1, "No use cases yet. Press c to create one.")
    see_action(t1, "]", "Next pane")
    press(t1, "]")
    # As far as the part's room needs (it shares the screen with the references).
    scrolled =
      Enum.find(1..10, fn _ ->
        press(t1, "NPage")
        settled(t1) =~ "1. it is stored and shown as written"
      end) || raise "the last line of the description never came into view"

    page = see(t1, "1. it is stored and shown as written")

    page =~
      ~r/## What[\s│]*\n[\s│]+- the title wraps[\s│]*\n[\s│]+- the description keeps its lines[\s│]*\n[\s│]*\n[\s│]+## Done when/u ||
      raise "the sections are not shown as written:\n#{page}"

    page =~ "No use cases yet. Press c to create one." || raise "the use cases went out of view"
    press(t1, List.duplicate("PPage", scrolled) ++ ["]"])
    see(t1, ~r/Scene SC-Atlas-\d+: Melle writes/)
  end

  step "rela keeps the line breaks", fn ->
    scene = Process.get(:scene)
    stored = AtlasE2E.Instance.rela_get(instance, "/scenes/#{scene}")
    description = stored["properties"]["description"]

    description ==
      "## Why\n\nBecause a scene tells a story, and a story takes more than one line.\n\n" <>
        "## What\n- the title wraps\n- the description keeps its lines\n\n" <>
        "## Done when\n1. it is stored and shown as written" ||
      raise "rela stored #{inspect(description)}"

    stored["properties"]["title"] == title ||
      raise "rela stored the title #{inspect(stored["properties"]["title"])}"
  end

  step "TUI 2 opens it with the same lines", fn ->
    open_row(t2, "Melle writes a scene")
    see(t2, ~r/Description\s+## Why[\s│]*\n[\s│]*\n[\s│]+Because a scene/u)
    # The long title wraps on the page too.
    see(t2, ~r/Title\s+Melle writes a scene.*\n[\s│]+.*second row/u)
  end

  step "Update: a line on top; arrows move; TUI 2 by hint", fn ->
    press(t1, "u")
    see(t1, ~r/Update SC-Atlas-\d+/)
    # Title, Status, then into the description at its first line.
    press(t1, ["Down", "Down"])
    see(t1, "Description")
    type(t1, "Intro")
    press(t1, "Enter")
    # Down to the end of "## What", and a word after it.
    press(t1, ["Down", "Down", "Down", "Down", "End"])
    type(t1, " (and how)")
    at = press(t1, "C-s")
    stored(t1, ~r/Description\s+Intro[\s│]*\n[\s│]+## Why/u, at)
    stored(t1, ~r/^[\s│]+## What \(and how\)[\s│]*$/mu, at)
    by_hint(t2, ~r/Description\s+Intro[\s│]*\n[\s│]+## Why/u, at)
  end

  step "A description longer than the screen scrolls around the cursor", fn ->
    press(t1, "u")
    see(t1, ~r/Update SC-Atlas-\d+/)
    press(t1, ["Down", "Down", "Down"])
    see(t1, "Description")

    for n <- 1..30 do
      type(t1, "extra line #{n}")
      press(t1, "Enter")
    end

    see(t1, "extra line 30")
    see(t1, "more below")
    refute_see(t1, "extra line 1\n")
    press(t1, "Escape")
    see(t1, ~r/Scene SC-Atlas-\d+:/)
    refute_see(t1, "extra line")
    resize(t1, 100, 30)
  end
end
