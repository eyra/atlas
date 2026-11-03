# UC-Atlas-30: lists and actions read the same everywhere (docs/guides/uc-atlas-30.md).
# IS-Atlas-59: a change moves an item to another parent, in the TUI and from the command line.
import AtlasE2E.Scenario

scenario "UC-Atlas-30: Move an issue to another use case", fn %{t1: t1, t2: t2, instance: i} ->
  put = fn args -> elem(atlas_json(i, ["put" | args]), 0)["key"] end

  scene = put.(["scene", "--title", "A scene with two use cases"])
  from = put.(["use_case", "--in", scene, "--title", "Where the issue starts"])
  to = put.(["use_case", "--in", scene, "--title", "Where the issue goes"])
  issue = put.(["issue", "--in", from, "--title", "An issue that moves"])

  step "TUI 1 on the issue, TUI 2 on the use case it will go to", fn ->
    for {t, use_case} <- [{t1, "Where the issue starts"}, {t2, "Where the issue goes"}] do
      open_row(t, "A scene with two use cases")
      see(t, ~r/Scene SC-Atlas-\d+: A scene with two use cases/)
      open_row(t, use_case)
      see(t, "Use case #{if t == t1, do: from, else: to}: #{use_case}")
    end

    see(t2, "No issues yet.")
    open_row(t1, "An issue that moves")
    see(t1, ~r/In use case[\s─│]+#{from}/u)
  end

  step "Update: the use case is a choice, the current one selected; choose the other", fn ->
    press(t1, "u")
    see(t1, "Update #{issue}")
    see(t1, "‹ #{from}: Where the issue starts ›")
    # Title, stage, description, then the use case.
    press(t1, ["Tab", "Tab", "Tab", "Right"])
    see(t1, "‹ #{to}: Where the issue goes ›")
    at = press(t1, "C-s")
    stored(t1, ~r/In use case[\s─│]+#{to}/u, at)
    by_hint(t2, "An issue that moves", at)
  end

  step "Back from the issue is its new use case; the old one has no issues left", fn ->
    press(t1, "Escape")
    see(t1, "Use case #{to}: Where the issue goes")
    see(t1, "An issue that moves")
    press(t1, "Escape")
    open_row(t1, "Where the issue starts")
    see(t1, "Use case #{from}: Where the issue starts")
    see(t1, "No issues yet.")
  end

  step "atlas set moves it back; TUI 1 and TUI 2 follow by hint", fn ->
    {out, 0, _} = atlas(i, ["help", "issue"])
    out =~ "in_use_case: the key of a use_case; a change moves it there" || raise out

    {item, at} = atlas_json(i, ["set", issue, "in_use_case=#{from}"])
    item["values"]["in_use_case"] == from || raise inspect(item)
    by_hint(t1, "An issue that moves", at)
    by_hint(t2, "An issue that moves", at, gone: true)
    see(t2, "No issues yet.")
  end

  step "A move to nothing, or to an item that does not exist, is refused", fn ->
    {answer, _} = atlas_json(i, ["set", issue, "in_use_case="], 1)

    answer["refused"] == ["in_use_case cannot be empty; choose where it goes"] ||
      raise inspect(answer)

    {answer, _} = atlas_json(i, ["set", issue, "in_use_case=UC-Atlas-99"], 1)
    answer["refused"] == ["UC-Atlas-99 does not exist"] || raise inspect(answer)
  end

  # IS-Atlas-58: every action is Create, Update or Delete, with the same words and keys.
  step "c Create, u Update, d Delete: the same words and keys on every page", fn ->
    home(t1)
    see(t1, "c Create scene")
    open_row(t1, "A scene with two use cases")
    # A person at the TUI also gets Accept (UC-Atlas-32), once a scenario made that person.
    see(t1, ~r/u Update scene\s+d Delete scene\s+(a Accept\s+)?c Create use case/)
    press(t1, "c")
    see(t1, ~r/^ Create use case in #{scene}$/m)
    see(t1, "[ Create ]")
    press(t1, "Escape")
    open_row(t1, "Where the issue starts")
    see(t1, ~r/u Update use case\s+d Delete use case\s+(a Accept\s+)?c Create issue/)
    press(t1, "u")
    see(t1, ~r/^ Update #{from}$/m)
    see(t1, "[ Update ]")
    press(t1, "Escape")
    see(t1, "Use case #{from}: Where the issue starts")
    press(t1, "d")
    see(t1, "#{from} cannot be deleted")
    press(t1, "Enter")
    see(t1, "Use case #{from}: Where the issue starts")
  end
end
