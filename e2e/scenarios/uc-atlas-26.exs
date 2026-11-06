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

    {made, _} =
      atlas_json(i, [
        "put",
        "issue",
        "--in",
        use_case["key"],
        "--title",
        "An issue whose code is on GitHub"
      ])

    Process.put(:uc26, %{issue: made["key"], use_case: use_case["key"]})

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

    press(t1, "c")
    see(t1, ~r/^ Create pull request in IS-Atlas-\d+$/m)
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
    press(t1, "u")
    see(t1, ~r/In issue \*\s+‹ IS-Atlas-\d+/)
    for field <- ["Title", "State", "Draft"], do: refute_see(t1, ~r/^\s+#{field}\s/m)
    press(t1, "Escape")
    see(t1, ~r/Last read\s+\d{4}-\d\d-\d\d/)
  end

  step "The issue's row: the title, then Open and draft; TUI 2 too", fn ->
    press(t1, "Escape")
    see(t1, issue)

    for t <- [t1, t2] do
      see(t, ~r/PR-eyra-atlas-e2e-2601  Repository skeleton with the layers[\s│]+Open · draft/)
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
        ~r/PR-eyra-atlas-e2e-2601  Repository skeleton with the layers[\s│]+Merged\s/,
        connector_wait
      )
    end

    Process.put(:uc26_reads, reads.(skeleton))
  end

  # IS-Atlas-60: an issue is one change, so it has one open or merged pull request.
  step "A second pull request for an issue whose first is merged is refused, and why", fn ->
    %{issue: key} = Process.get(:uc26)

    refusal =
      "#{key} already has PR-eyra-atlas-e2e-2601 (Merged); an issue is one change: " <>
        "close that PR first, or make a new issue"

    press(t1, "c")
    see(t1, ~r/^ Create pull request in IS-Atlas-\d+$/m)
    type(t1, flaky)
    at = press(t1, "C-s")
    stored(t1, "#{key} already has PR-eyra-atlas-e2e-2601 (Merged); an issue is one change", at)
    see(t1, "Not sent: the form says why.")
    press(t1, "Escape")
    see(t1, issue)

    {answer, _} = atlas_json(i, ["put", "pull_request", "--in", key, "--url", flaky], 1)
    answer["refused"] == [refusal] || raise inspect(answer)
    {got, _} = atlas_json(i, ["get", key])
    length(hd(got["lists"])["rows"]) == 1 || raise inspect(got["lists"])
  end

  step "A read that fails: the page says so, and the next round tries again", fn ->
    %{use_case: use_case} = Process.get(:uc26)
    atlas_json(i, ["put", "issue", "--in", use_case, "--title", "A second change on GitHub"])
    GitHub.put(flaky, {:status, 503})
    press(t1, "Escape")
    open_row(t1, "A second change on GitHub")
    see(t1, ~r/Issue IS-Atlas-\d+: A second change on GitHub/)
    press(t1, "c")
    see(t1, ~r/^ Create pull request in IS-Atlas-\d+$/m)
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

  # IS-Atlas-69: a merged pull request whose title names another issue was done for it
  # too; the connector records done_in, so that issue shows Done and "Also done in".
  step "A merged pull request whose title names another issue makes it Done too", fn ->
    %{use_case: use_case} = Process.get(:uc26)

    {other, _} =
      atlas_json(i, ["put", "issue", "--in", use_case, "--title", "Done in the flaky one"])

    key = other["key"]

    GitHub.put(flaky, %{
      "title" => "A flaky one, which also does #{key}",
      "state" => "closed",
      "merged" => true,
      "html_url" => flaky
    })

    deadline = System.monotonic_time(:millisecond) + connector_wait + 2_000

    got =
      Stream.repeatedly(fn ->
        {got, _} = atlas_json(i, ["get", key])
        got
      end)
      |> Enum.find(fn got ->
        Enum.any?(got["fields"], &(&1 == ["Also done in", "PR-eyra-atlas-e2e-2602"])) or
          (System.monotonic_time(:millisecond) > deadline || (Process.sleep(500) && false))
      end)

    Enum.any?(got["fields"], &(&1 == ["Also done in", "PR-eyra-atlas-e2e-2602"])) ||
      raise "#{key} has no done_in: #{inspect(got["fields"])}"

    progress = Enum.find_value(got["fields"], fn [l, v] -> l == "Progress" && v end)
    progress == "Done · PR-eyra-atlas-e2e-2602 merged" || raise inspect(got["fields"])
  end
end
