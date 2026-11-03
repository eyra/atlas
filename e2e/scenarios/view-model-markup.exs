# Markup on a scene's page: a border around the scene, a section for its use cases
# (spec/control/README.md, "Markup").
import AtlasE2E.Scenario

scenario "Markup: a border around the scene, a section for its use cases", fn %{t1: t1, t2: t2} ->
  step "A scene's page: the scene in a border, its use cases in a section", fn ->
    home(t1)
    press(t1, "n")
    see(t1, ~r/^ New scene$/m)
    type(t1, "A scene with markup")
    at = press(t1, "C-s")
    page = stored(t1, ~r/Scene SC-Atlas-\d+: A scene with markup/, at)

    # The border's corners and sides, around the scene's own block only.
    page =~ ~r/^ ┌─+┐$/mu || raise "no border top:\n#{page}"

    page =~ ~r/^ │ Scene SC-Atlas-\d+: A scene with markup\s+│$/mu ||
      raise "the title is not in the border:\n#{page}"

    page =~ ~r/^ │   Status\s+Refine\s+│$/mu || raise "the fields are not in the border:\n#{page}"
    page =~ ~r/^ └─+┘\n\n Use cases ─+$/mu || raise "no section after the border:\n#{page}"

    # The section carries the list's title; the list does not repeat it.
    page =~ ~r/ Use cases ─+\n\n   No use cases yet\. Press a to add one\./u ||
      raise "the section does not head the list:\n#{page}"
  end

  step "A use case added shows in the section; TUI 2 draws the same", fn ->
    press(t1, "a")
    see(t1, ~r/^ New use case in SC-Atlas-\d+$/m)
    type(t1, "A use case in the section")
    at = press(t1, "C-s")
    stored(t1, ~r/✓ Stored as UC-Atlas-\d+/, at)

    # A use case's page is marked up the same way: its issues in a section.
    page = see(t1, ~r/ Issues ─+\n\n   No issues yet\./u)

    page =~ ~r/^ │ Use case UC-Atlas-\d+: A use case in the section\s+│$/mu ||
      raise "no border:\n#{page}"

    press(t1, "Escape")
    see(t1, ~r/ Use cases ─+\n\n › A use case in the section\s+UC-Atlas-\d+/u)

    home(t2)
    open_row(t2, "A scene with markup")
    see(t2, ~r/^ │ Scene SC-Atlas-\d+: A scene with markup\s+│$/mu)

    see(
      t2,
      ~r/ Use cases ─+\n\n   A use case in the section\s+UC-Atlas-\d+|› A use case in the section/u
    )
  end
end
