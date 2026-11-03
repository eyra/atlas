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
  """

  alias AtlasE2E.Tui

  @page_wait 3_000
  @first_page ~r/● connected · /
  @quick 1_000
  @poll 20

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

  @doc "Press keys (tmux names); returns when they were sent, for `stored/3` and `by_hint/3`."
  def press(tui, keys) do
    at = %{ms: now(), clock: clock()}
    Tui.keys(tui, List.wrap(keys))
    at
  end

  def type(tui, text), do: Tui.type(tui, text)

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
    screen = Tui.screen(tui)

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
    screen = Tui.screen(tui)

    case Regex.run(regex, screen) do
      [_, value | _] -> value
      _ -> fail(tui, "shows nothing like #{inspect(regex)}", screen)
    end
  end

  # Moving around

  @doc "Back to the start page: escape until there is nothing to go back to."
  def home(tui) do
    Enum.reduce_while(1..8, nil, fn _, _ ->
      screen = Tui.screen(tui)

      if screen =~ ~r/esc (back|cancel)|y confirm|↵ back/ do
        Tui.keys(tui, [if(screen =~ "y confirm", do: "n", else: "Escape")])
        wait(tui, @page_wait, &(&1 != screen), "change page")
        {:cont, nil}
      else
        {:halt, nil}
      end
    end)

    see(tui, @first_page)
  end

  @doc """
  Connected, and the first page is on screen. "● connected" alone shows as soon as
  Control welcomes the TUI, before its first page; a key pressed then has nothing to act on.
  """
  def ready(tui, within \\ @page_wait), do: see(tui, @first_page, within)

  @doc "Select the row of a list that shows `text`, and open it."
  def open_row(tui, text) do
    Enum.reduce_while(1..40, nil, fn _, _ ->
      screen = Tui.screen(tui)

      cond do
        screen =~ ~r/› .*#{Regex.escape(text)}/ ->
          Tui.keys(tui, ["Enter"])
          {:halt, :ok}

        true ->
          Tui.keys(tui, ["Down"])
          wait(tui, @page_wait, &(&1 != screen), "move to #{inspect(text)}", true)
          {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      _ -> fail(tui, "has no row #{inspect(text)}", Tui.screen(tui))
    end
  end

  # Waiting

  defp quick(tui, at, ok?, what, note) do
    left = max(at.ms + @quick - now(), 0)
    screen = wait(tui, left, ok?, "#{what} within #{@quick} ms of the key")
    Process.put(:e2e_notes, ["#{note} in #{now() - at.ms} ms" | Process.get(:e2e_notes)])
    screen
  end

  defp wait(tui, within, ok?, what, quiet \\ false) do
    deadline = now() + within
    poll(tui, deadline, ok?, what, quiet)
  end

  defp poll(tui, deadline, ok?, what, quiet) do
    screen = Tui.screen(tui)

    cond do
      ok?.(screen) ->
        screen

      now() >= deadline ->
        if quiet, do: screen, else: fail(tui, "did not #{what}", screen)

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
