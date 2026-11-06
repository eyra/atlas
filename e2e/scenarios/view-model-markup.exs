# Markup on a scene's page: two parts, its content (main) and its references (related),
# which the TUI draws as boxes side by side when the terminal is wide (bff/README.md,
# "Markup"; IS-Atlas-48, IS-Atlas-66).
import AtlasE2E.Scenario

scenario "Markup: a scene's page in two parts, content and references", fn %{
                                                                             t1: t1,
                                                                             t2: t2,
                                                                             instance: i
                                                                           } ->
  step "A scene's page: the scene in the content part, its use cases in the references", fn ->
    home(t1)
    press(t1, "c")
    see(t1, ~r/^ Create scene$/m)
    type(t1, "A scene with markup")
    at = press(t1, "C-s")
    page = stored(t1, ~r/Scene SC-Atlas-\d+: A scene with markup/, at)

    # One above the other at 100 columns: the content first, then the references.
    page =~ ~r/^ ┌─ Content ─+┐$/mu || raise "no content part:\n#{page}"

    page =~ ~r/^ │ Scene SC-Atlas-\d+: A scene with markup\s+│$/mu ||
      raise "the title is not in the content part:\n#{page}"

    page =~ ~r/^ │   Flux group\s+Refine\s+│$/mu ||
      raise "the fields are not in the content part:\n#{page}"

    page =~ ~r/^ └─+┘\n ┌─ References ─+┐\n │ Use cases ─+ │$/mu ||
      raise "no references part after the content:\n#{page}"

    # The section carries the list's title; the list does not repeat it.
    page =~ ~r/ Use cases ─+ │\n │\s+│\n │   No use cases yet\. Press c to create one\./u ||
      raise "the section does not head the list:\n#{page}"

    see_action(t1, "]", "Next pane")
  end

  step "A use case added shows in the references; its page has two parts too", fn ->
    press(t1, "c")
    see(t1, ~r/^ Create use case in SC-Atlas-\d+$/m)
    type(t1, "A use case in the section")
    at = press(t1, "C-s")
    stored(t1, ~r/✓ Stored as UC-Atlas-\d+/, at)

    # A use case's references: its issues, and the scene it is in, to open from here.
    page = see(t1, ~r/ Issues ─+ │\n │\s+│\n │   No issues yet\./u)

    page =~ ~r/ In scene ─+ │\n │\s+│\n │ [ ›] SC-Atlas-\d+\s+Scene/u ||
      raise "no scene:\n#{page}"

    page =~ ~r/^ │ Use case UC-Atlas-\d+: A use case in the section\s+│$/mu ||
      raise "no content part:\n#{page}"

    press(t1, "Escape")
    see(t1, ~r/ Use cases ─+ │\n │\s+│\n │ › UC-Atlas-\d+\s+A use case in the section/u)
  end

  step "Wide: the two parts side by side; brackets move the focus", fn ->
    home(t2)
    open_row(t2, "A scene with markup")
    resize(t2, 160, 30)
    page = see(t2, ~r/┌─ Content ─+┐ +┌─ References ─+┐/u)
    page =~ ~r/│ Scene SC-Atlas-\d+: A scene with markup\s+│ +│ Use cases ─+ │/u || raise page
    see(t2, ~r/UC-Atlas-\d+\s+A use case in the section/)
    see(t2, ~r/› UC-Atlas-\d+\s+A use case in the section/)
    see_action(t2, "]", "Next pane")
    press(t2, "]")
    see(t2, ~r/UC-Atlas-\d+\s+A use case in the section/)
    press(t2, "]")
    see(t2, ~r/› UC-Atlas-\d+\s+A use case in the section/)
    see(t2, "▸ Scenes")
    resize(t2, 100, 30)
    see(t2, ~r/^ └─+┘\n ┌─ References/mu)
  end

  step "Manual References scroll hides the offscreen selection; row movement restores it", fn ->
    scene = capture(t2, ~r/Scene (SC-Atlas-\d+): A scene with markup/)

    for n <- 1..8 do
      atlas_json(i, [
        "put",
        "use_case",
        "--in",
        scene,
        "--title",
        "A reference for scrolling #{n}"
      ])
    end

    see(t2, ~r/› UC-Atlas-\d+\s+A use case in the section/)
    press(t2, "NPage")
    gone(t2, ~r/│ › UC-Atlas-\d+/)
    refute_see(t2, ~r/│ › UC-Atlas-\d+/)
    see(t2, "▸ Scenes")
    press(t2, "j")
    see(t2, ~r/│ › UC-Atlas-\d+\s+A reference for scrolling/)
  end
end
