# UC-Atlas-04: link the pull requests of an issue (docs/guides/uc-atlas-04.md).
import AtlasE2E.Scenario

url = "https://github.com/eyra/atlas/pull/12"

scenario "UC-Atlas-04: Link the pull requests of an issue", fn %{t1: t1, t2: t2} ->
  issue = ~r/Issue IS-Atlas-\d+: An issue with pull requests/

  step "An issue, with no pull requests yet", fn ->
    press(t1, "n")
    see(t1, ~r/^ New scene$/m)
    type(t1, "A scene for pull requests")
    at = press(t1, "C-s")
    stored(t1, ~r/Scene SC-Atlas-\d+: A scene for pull requests/, at)
    press(t1, "a")
    see(t1, ~r/^ New use case in/m)
    type(t1, "A use case for pull requests")
    at = press(t1, "C-s")
    stored(t1, ~r/Use case UC-Atlas-\d+: A use case for pull requests/, at)
    press(t1, "a")
    see(t1, ~r/^ New issue in/m)
    type(t1, "An issue with pull requests")
    at = press(t1, "C-s")
    stored(t1, issue, at)
    see(t1, "No pull requests yet. Press a to add one.")

    open_row(t2, "A scene for pull requests")
    see(t2, ~r/Scene SC-Atlas-\d+: A scene for pull requests/)
    open_row(t2, "A use case for pull requests")
    see(t2, ~r/Use case UC-Atlas-\d+: A use case for pull requests/)
    open_row(t2, "An issue with pull requests")
    see(t2, issue)
  end

  step "Link one: only its URL; the id is made from it", fn ->
    press(t1, "a")
    see(t1, ~r/^ New pull request in IS-Atlas-\d+$/m)
    see(t1, "Url *")
    for field <- ["Title", "State", "Draft"], do: refute_see(t1, field)
    type(t1, url)
    at = press(t1, "C-s")
    stored(t1, "✓ Stored as PR-eyra-atlas-12", at)
    page = stored(t1, "Pull request PR-eyra-atlas-12: #{url}", at)
    page =~ ~r/In issue\s+IS-Atlas-\d+/ || raise "it is not in the issue"
    # Nothing a person may change: no Change action; title and state come from GitHub.
    refute_see(t1, "e Change")
    refute_see(t1, ~r/Title\s/)
    by_hint(t2, url, at)
  end

  step "The same URL again is the same pull request", fn ->
    press(t1, "Escape")
    see(t1, issue)
    press(t1, "a")
    see(t1, ~r/^ New pull request in IS-Atlas-\d+$/m)
    type(t1, url)
    at = press(t1, "C-s")
    stored(t1, "Pull request PR-eyra-atlas-12: #{url}", at)
    press(t1, "Escape")
    screen = see(t1, issue)
    length(String.split(screen, url)) == 2 || raise "the issue lists it more than once"
  end

  step "A URL that is not a GitHub pull request is never sent", fn ->
    press(t1, "a")
    see(t1, ~r/^ New pull request in IS-Atlas-\d+$/m)
    type(t1, "https://gitlab.com/eyra/atlas/-/merge_requests/3")
    at = press(t1, "C-s")
    stored(t1, "url must be a GitHub pull request URL", at)
    see(t1, "Not sent: the form says why.")
    press(t1, "Escape")
    see(t1, issue)
  end

  step "An issue with a pull request cannot be deleted", fn ->
    press(t1, "d")
    see(t1, "cannot be deleted")
    see(t1, ~r/still has 1 pull request\. Remove it first/)
    press(t1, "Enter")
    see(t1, issue)
  end

  step "The same URL from another issue is refused", fn ->
    press(t1, "Escape")
    see(t1, ~r/Use case UC-Atlas-\d+: A use case for pull requests/)
    press(t1, "a")
    see(t1, ~r/^ New issue in/m)
    type(t1, "Another issue")
    at = press(t1, "C-s")
    stored(t1, ~r/Issue IS-Atlas-\d+: Another issue/, at)
    press(t1, "a")
    see(t1, ~r/^ New pull request in IS-Atlas-\d+$/m)
    type(t1, url)
    at = press(t1, "C-s")
    stored(t1, "PR-eyra-atlas-12 already exists", at)
    press(t1, "Escape")
    see(t1, ~r/Issue IS-Atlas-\d+: Another issue/)
    see(t1, "No pull requests yet.")
  end

  step "Remove it; back in its issue; TUI 2 by hint", fn ->
    press(t1, "Escape")
    see(t1, ~r/Use case UC-Atlas-\d+: A use case for pull requests/)
    open_row(t1, "An issue with pull requests")
    see(t1, issue)
    open_row(t1, url)
    see(t1, "Pull request PR-eyra-atlas-12")
    press(t1, "d")
    see(t1, "Delete pull request PR-eyra-atlas-12?")
    at = press(t1, "y")
    stored(t1, issue, at)
    see(t1, "No pull requests yet.")
    by_hint(t2, url, at, gone: true)
  end
end
