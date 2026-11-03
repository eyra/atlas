defmodule AtlasE2E.Scenario do
  @moduledoc """
  What a scenario file (`e2e/scenarios/*.exs`) is written in. A scenario follows the
  guide of its use case, step by step, on two TUIs (`t1`, `t2`).

  Waiting is for screen text, never a sleep. Two speeds:

  - `see/3` waits for a page to show, up to #{3_000} ms.
  - `stored/3` and `by_hint/3` are the speed Melle gets: TUI 1 shows its stored change,
    and TUI 2 shows it by hint, within 1 second of the key that saved it. Every TUI also
    reconciles every 5 seconds, but that is a fallback: a change that shows only by a
    reconcile, or later than 1 second, fails the step.

  What makes a check trustworthy on a busy machine (IS-Atlas-68), here for every
  scenario rather than in each:

  - A screen counts only once it has settled: the TUI writes a frame in pieces, and a
    capture between two pieces shows half a page. A match is checked again on the
    settled screen (`settled/1`), and that screen is what a step reads on.
  - A key goes to a settled screen, so it acts on the page it was meant for, and the
    1 second of `stored/3` and `by_hint/3` starts when it is sent.
  - A check that is about to fail reads the screen once more.
  - The TUIs wait longer for the rest of a key's escape sequence (`escape_ms` in the
    run's settings), so `\\e[B` never turns into Escape and "[B".
  """

  alias AtlasE2E.Tui

  @page_wait 3_000
  @first_page ~r/● connected · /
  @quick 1_000
  @poll 20
  # A screen has settled when two captures this far apart are the same.
  @settle 40
  # How long a key waits for a screen that keeps changing (a running plan) before it goes.
  @settle_wait 1_000

  defmodule Failure do
    defexception [:message]
  end

  def scenario(title, fun), do: %{title: title, fun: fun}

  @doc "One step of the guide: its name, and what it does and checks."
  def step(name, fun) do
    Process.put(:e2e_notes, [])
    Process.put(:e2e_step, name)
    started = now()

    try do
      fun.()
    rescue
      error ->
        IO.puts("  ✗ #{name}: #{Exception.message(error)}")
        reraise error, __STACKTRACE__
    end

    notes = Process.get(:e2e_notes) |> Enum.reverse()
    took = Float.round((now() - started) / 1000, 1)
    IO.puts("  ✓ #{Enum.join(["#{name} (#{took} s)" | notes], " · ")}")
    Process.put(:e2e_steps, (Process.get(:e2e_steps) || 0) + 1)
    :ok
  end

  # Keys

  @doc """
  Press keys (tmux names) on the settled screen; returns when they were sent, for
  `stored/3` and `by_hint/3`.
  """
  def press(tui, keys) do
    settled(tui)
    at = %{ms: now(), clock: clock()}
    Tui.keys(tui, List.wrap(keys))
    at
  end

  def type(tui, text) do
    settled(tui)
    Tui.type(tui, text)
  end

  @doc """
  The screen once it has settled: two captures #{40} ms apart that are the same. A screen
  that keeps changing (a plan that runs) is taken as it is after #{1_000} ms.
  """
  def settled(tui) do
    screen = Tui.screen(tui)

    # The same as the last settled screen of this TUI is a whole frame already: no wait.
    if screen == Process.get({:settled, tui.name}),
      do: screen,
      else: settled(tui, screen, now() + @settle_wait)
  end

  defp settled(tui, screen, deadline) do
    Process.sleep(@settle)
    again = Tui.screen(tui)

    cond do
      again == screen -> remember(tui, screen)
      now() >= deadline -> again
      true -> settled(tui, again, deadline)
    end
  end

  defp remember(tui, screen) do
    Process.put({:settled, tui.name}, screen)
    screen
  end

  @doc "Resize the TUI's terminal; the TUI redraws for its new size by itself."
  def resize(tui, width, height), do: Tui.resize(tui, width, height)

  # The command line

  @doc """
  Run `atlas <args> --env test` on the private instance, as an agent would, with
  `input` on stdin. Returns `{stdout, exit status, at}`; `at` is for `by_hint/3`: its
  1 second starts when the command has answered (it answers once State stored).
  """
  def atlas(instance, args, input \\ "") do
    clock = clock()
    stdin = Path.join(instance.dir, "stdin-#{System.unique_integer([:positive])}")
    File.write!(stdin, input)

    {out, status} =
      System.cmd(
        "sh",
        ["-c", ~s|exec "$0" "$@" < "#{stdin}"|, Path.join(instance.root, "bin/atlas")] ++
          args ++ ["--env", "test"],
        env: instance.env,
        cd: instance.dir
      )

    File.rm(stdin)
    {out, status, %{ms: now(), clock: clock}}
  end

  @doc "`atlas/3` with `--json`, decoded; fails the step on another exit status than `status`."
  def atlas_json(instance, args, status \\ 0, input \\ "") do
    {out, got, at} = atlas(instance, args ++ ["--json"], input)

    if got != status,
      do:
        raise(Failure,
          message: "atlas #{Enum.join(args, " ")} exited #{got}, not #{status}: #{out}"
        )

    {JSON.decode!(out), at}
  end

  # Seeing

  @doc "Wait until the screen matches (a string or a regex); returns the screen."
  def see(tui, pattern, within \\ @page_wait) do
    wait(tui, within, &matches?(&1, pattern), "show #{inspect(pattern)}")
  end

  @doc "Wait until the screen no longer matches."
  def gone(tui, pattern, within \\ @page_wait) do
    wait(tui, within, &(not matches?(&1, pattern)), "stop showing #{inspect(pattern)}")
  end

  def refute_see(tui, pattern) do
    screen = settled(tui)

    if matches?(screen, pattern),
      do: fail(tui, "shows #{inspect(pattern)}, which it should not", screen)

    screen
  end

  @doc "TUI 1 shows its own change as stored within 1 second of `at`."
  def stored(tui, pattern, at) do
    screen = quick(tui, at, &matches?(&1, pattern), "show #{inspect(pattern)}", "stored")
    screen
  end

  @doc """
  The other TUI shows the change (`pattern` matches, or with `gone: true` no longer
  matches) by hint, within 1 second of `at`.
  """
  def by_hint(tui, pattern, at, opts \\ []) do
    shown =
      if opts[:gone],
        do: &(not matches?(&1, pattern)),
        else: &matches?(&1, pattern)

    quick(
      tui,
      at,
      &(shown.(&1) and hinted_since?(&1, at.clock)),
      "show the change (#{inspect(pattern)}) by hint",
      "#{tui.label} by hint"
    )
  end

  @doc "The first group of `regex` on the screen."
  def capture(tui, regex) do
    screen = settled(tui)

    case Regex.run(regex, screen) do
      [_, value | _] -> value
      _ -> fail(tui, "shows nothing like #{inspect(regex)}", screen)
    end
  end

  @doc """
  The stand-in browser got `url` as the run's `count`th opened address, within 1 second
  of `at`.
  """
  def opened(instance, url, at, count) do
    opened = AtlasE2E.Instance.opened(instance)

    cond do
      length(opened) >= count ->
        Enum.at(opened, count - 1) == url ||
          raise Failure, "the browser got #{inspect(opened)}, not #{url}"

        Process.put(:e2e_notes, ["opened in #{now() - at.ms} ms" | Process.get(:e2e_notes)])
        opened

      now() > at.ms + @quick ->
        raise Failure, "the browser got nothing within #{@quick} ms (#{inspect(opened)})"

      true ->
        Process.sleep(@poll)
        opened(instance, url, at, count)
    end
  end

  # Moving around

  @doc """
  Back to the start page: escape until there is nothing to go back to. An agent's plan
  counts as something to leave (`↵ close` when it is over, `esc stop` while it runs), so
  a key that closed a plan but has not been drawn yet does not look like the start page.
  """
  def home(tui) do
    Enum.reduce_while(1..8, nil, fn _, _ ->
      screen = settled(tui)

      if screen =~ ~r/esc (back|cancel|stop)|y confirm|↵ (back|close)/ do
        Tui.keys(tui, [if(screen =~ "y confirm", do: "n", else: "Escape")])
        wait(tui, @page_wait, &(&1 != screen), "change page")
        {:cont, nil}
      else
        {:halt, nil}
      end
    end)

    screen = see(tui, @first_page)

    # The user is a person: the start page is what is assigned to them (IS-Atlas-55), and
    # the scenes are one key away. Scenarios go on from the scenes, as before.
    if screen =~ "s Scenes" do
      Tui.keys(tui, ["s"])
      see(tui, ~r/Atlas · test.*\sScenes$/m)
    else
      screen
    end
  end

  @doc """
  Connected, and the first page is on screen. "● connected" alone shows as soon as
  Control welcomes the TUI, before its first page; a key pressed then has nothing to act on.
  """
  def ready(tui, within \\ @page_wait), do: see(tui, @first_page, within)

  @doc "Select the row of a list that shows `text`, and open it."
  def open_row(tui, text) do
    # A row that is still on its way (by hint) is waited for first: moving down before it
    # is there could move the selection past it. On a list longer than the screen the row
    # may be below it, out of sight; moving down brings it in.
    wait(
      tui,
      @page_wait,
      &(&1 =~ text or &1 =~ "pgup/pgdn scroll"),
      "show #{inspect(text)}"
    )

    Enum.reduce_while(1..40, nil, fn _, _ ->
      screen = settled(tui)

      cond do
        screen =~ ~r/› .*#{Regex.escape(text)}/ ->
          Tui.keys(tui, ["Enter"])
          {:halt, :ok}

        # j, not Down: an arrow is an escape sequence, and under load its esc can arrive on
        # its own and go back a page (from the scenes list to the start page, IS-Atlas-55).
        true ->
          Tui.keys(tui, ["j"])
          wait(tui, @page_wait, &(&1 != screen), "move to #{inspect(text)}", true)
          {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      _ -> fail(tui, "has no row #{inspect(text)}", settled(tui))
    end
  end

  # Waiting

  # The time is the first capture that matched; confirming it takes a moment more.
  defp quick(tui, at, ok?, what, note) do
    left = max(at.ms + @quick - now(), 0)
    {screen, seen} = wait_at(tui, left, ok?, "#{what} within #{@quick} ms of the key")
    Process.put(:e2e_notes, ["#{note} in #{seen - at.ms} ms" | Process.get(:e2e_notes)])
    screen
  end

  defp wait(tui, within, ok?, what, quiet \\ false),
    do: tui |> wait_at(within, ok?, what, quiet) |> elem(0)

  defp wait_at(tui, within, ok?, what, quiet \\ false) do
    deadline = now() + within
    poll(tui, deadline, ok?, what, quiet)
  end

  # A match counts only on a settled screen, so never on half a frame.
  defp poll(tui, deadline, ok?, what, quiet) do
    seen = now()
    screen = Tui.screen(tui)

    cond do
      ok?.(screen) ->
        last = settled(tui)

        cond do
          ok?.(last) -> {last, seen}
          # A screen that keeps flipping in and out of the match: take the match.
          now() >= deadline + @settle_wait -> {screen, seen}
          true -> poll(tui, deadline, ok?, what, quiet)
        end

      # At the deadline one more capture, at once: the last one may be from just before a
      # redraw. It does not stretch the time limit by more than that one read.
      seen >= deadline ->
        read_at = now()
        last = Tui.screen(tui)

        cond do
          ok?.(last) -> {settled(tui), read_at}
          quiet -> {last, seen}
          true -> fail(tui, "did not #{what}", settled(tui))
        end

      true ->
        Process.sleep(@poll)
        poll(tui, deadline, ok?, what, quiet)
    end
  end

  defp fail(tui, text, screen),
    do: raise(Failure, message: "#{tui.label} #{text}. Its screen:\n#{indent(screen)}")

  defp indent(screen), do: screen |> String.split("\n") |> Enum.map_join("\n", &("    | " <> &1))

  # The status line names the last hint's time ("updated by hint at", "last hint at").
  defp hinted_since?(screen, clock) do
    case Regex.run(~r/(?:updated by hint|last hint) at (\d\d:\d\d:\d\d)/, screen) do
      [_, time] -> time >= clock
      nil -> false
    end
  end

  defp matches?(screen, %Regex{} = regex), do: Regex.match?(regex, screen)
  defp matches?(screen, text) when is_binary(text), do: String.contains?(screen, text)

  defp now, do: System.monotonic_time(:millisecond)

  defp clock,
    do:
      NaiveDateTime.local_now()
      |> NaiveDateTime.to_time()
      |> Time.truncate(:second)
      |> Time.to_iso8601()
end
