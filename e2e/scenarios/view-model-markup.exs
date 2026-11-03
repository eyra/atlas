# Markup on a scene's page: two parts, its content (main) and its references (related),
# which the TUI draws as boxes side by side when the terminal is wide (bff/README.md,
# "Markup"; IS-Atlas-48, IS-Atlas-66).
import AtlasE2E.Scenario

scenario "Markup: a scene's page in two parts, content and references", fn %{t1: t1, t2: t2} ->
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

    page =~ "tab next part" || raise "the footer does not say tab moves between the parts"
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

  step "Wide: the two parts side by side; tab moves the focus", fn ->
    home(t2)
    open_row(t2, "A scene with markup")
    resize(t2, 160, 30)
    page = see(t2, ~r/┌─ Content ─+┐ +┌─ References ─+┐/u)
    page =~ ~r/│ Scene SC-Atlas-\d+: A scene with markup\s+│ +│ Use cases ─+ │/u || raise page
    see(t2, ~r/UC-Atlas-\d+\s+A use case in the section/)
    see(t2, "↑↓ move")
    press(t2, "Tab")
    see(t2, "↑↓ scroll")
    press(t2, "Tab")
    see(t2, "↑↓ move")
    resize(t2, 100, 30)
    see(t2, ~r/^ └─+┘\n ┌─ References/mu)
  end
end
