# UC-Atlas-26: see each pull request's title and state from GitHub (docs/guides/uc-atlas-26.md).
# GitHub is the stand-in AtlasE2E.GitHub, read every 2 seconds instead of every 5 minutes.
import AtlasE2E.Scenario

alias AtlasE2E.GitHub

skeleton = "https://github.com/eyra/atlas-e2e/pull/2601"
flaky = "https://github.com/eyra/atlas-e2e/pull/2602"
# A connector's change shows by its hint, at most one round (2 s) after GitHub changed.
connector_wait = 5_000
reads = fn url -> Enum.count(GitHub.requests(), &(&1.path == GitHub.path(url))) end

scenario "UC-Atlas-26: See each pull request's title and state from GitHub", fn ctx ->
  %{t1: t1, t2: t2, instance: i} = ctx
  issue = ~r/Issue IS-Atlas-\d+: An issue whose code is on GitHub/

  step "An issue made from the command line; both TUIs open it", fn ->
    {scene, _} = atlas_json(i, ["put", "scene", "--title", "A scene on GitHub"])
    {use_case, _} = atlas_json(i, ["put", "use_case", "--in", scene["key"], "--title", "Its UC"])

    atlas_json(i, [
      "put",
      "issue",
      "--in",
      use_case["key"],
      "--title",
      "An issue whose code is on GitHub"
    ])

    for t <- [t1, t2] do
      open_row(t, "A scene on GitHub")
      open_row(t, "Its UC")
      open_row(t, "An issue whose code is on GitHub")
      see(t, issue)
    end
  end

  step "Linked a moment ago: its title, state and draft within seconds", fn ->
    GitHub.put(skeleton, %{
      "title" => "Repository skeleton with the layers",
      "state" => "open",
      "draft" => true,
      "merged" => false,
      "html_url" => skeleton
    })

    press(t1, "a")
    see(t1, ~r/^ New pull request in IS-Atlas-\d+$/m)
    type(t1, skeleton)
    at = press(t1, "C-s")
    stored(t1, "✓ Stored as PR-eyra-atlas-e2e-2601", at)

    see(
      t1,
      "Pull request PR-eyra-atlas-e2e-2601: Repository skeleton with the layers",
      connector_wait
    )

    see(t1, ~r/State\s+Open/)
    see(t1, ~r/Draft\s+yes/)
    see(t1, ~r/Last read\s+\d{4}-\d\d-\d\d \d\d:\d\d UTC from GitHub/)
    # Still GitHub's: a change only moves it to another issue, and never sets them.
    press(t1, "e")
    see(t1, ~r/In issue \*\s+‹ IS-Atlas-\d+/)
    for field <- ["Title", "State", "Draft"], do: refute_see(t1, ~r/^\s+#{field}\s/m)
    press(t1, "Escape")
    see(t1, ~r/Last read\s+\d{4}-\d\d-\d\d/)
  end

  step "The issue's row: the title, then Open and draft; TUI 2 too", fn ->
    press(t1, "Escape")
    see(t1, issue)

    for t <- [t1, t2] do
      see(t, ~r/Repository skeleton with the layers\s+PR-eyra-atlas-e2e-2601 · Open · draft/)
    end
  end

  step "Merged on GitHub: Merged within a round, without anyone touching Atlas", fn ->
    GitHub.put(skeleton, %{
      "title" => "Repository skeleton with the layers",
      "state" => "closed",
      "draft" => false,
      "merged" => true,
      "html_url" => skeleton
    })

    for t <- [t1, t2] do
      see(
        t,
        ~r/Repository skeleton with the layers\s+PR-eyra-atlas-e2e-2601 · Merged\s/,
        connector_wait
      )
    end

    Process.put(:uc26_reads, reads.(skeleton))
  end

  step "A read that fails: the page says so, and the next round tries again", fn ->
    GitHub.put(flaky, {:status, 503})
    press(t1, "a")
    see(t1, ~r/^ New pull request in IS-Atlas-\d+$/m)
    type(t1, flaky)
    at = press(t1, "C-s")
    stored(t1, "Pull request PR-eyra-atlas-e2e-2602: #{flaky}", at)

    # A failed read stores nothing, so there is no hint: the TUI's reconcile (5 s) shows it.
    see(
      t1,
      ~r/Last read\s+never from GitHub; the read at .* UTC failed: GitHub answered/,
      connector_wait + 5_000
    )

    GitHub.put(flaky, %{"title" => "A flaky one", "state" => "open", "draft" => false})
    see(t1, "Pull request PR-eyra-atlas-e2e-2602: A flaky one", connector_wait)
    see(t1, ~r/Last read\s+\d{4}-\d\d-\d\d \d\d:\d\d UTC from GitHub/)
    gone(t1, "GitHub answered 503")
  end

  step "A merged one is read no more; every read was a GET with the token", fn ->
    # Rounds ran meanwhile (the failing read took at least one); none read the merged one.
    reads.(skeleton) == Process.get(:uc26_reads) ||
      raise "the merged pull was read again: #{reads.(skeleton)} reads"

    requests = GitHub.requests()
    requests != [] || raise "the connector read nothing"

    for r <- requests do
      (r.method == "GET" and r.authorization == "Bearer #{GitHub.token()}") ||
        raise "not a read with the token: #{inspect(r)}"
    end
  end
end
