defmodule AtlasRuntime.Agent.Claude do
  @moduledoc """
  Claude Code, headless, as the agent behind a turn (IS-Atlas-18; the design part is
  `~/agent-reports/atlas/2026-11-04-is-18-claude-port-design.md`). One OS process per turn,
  owned by this process through an Erlang port:

  - it runs `claude -p` with `--output-format stream-json`, confined: `--restricted`, no MCP,
    Bash only for the `atlas` commands it is allowed, nobody asked for permission;
  - in a fresh folder of its own (`turns_dir/<turn key>`), with an environment cleared down
    to a few names (no token or other setting of the machine's reaches it), `ATLAS_AS` set
    to the agent, so what it writes through `atlas` is by it, and a PATH of one folder that
    holds only a wrapper `atlas`: the machine's instance alone (it refuses `--env`, another
    `ATLAS_ENV_FILE`, and any command but get, list and set), never prod or test;
  - every line it prints is kept in its folder (`stream.jsonl`), for what it ran and cost;
  - every line it prints is activity; it exiting 0 ends the turn with its result, any other
    exit is a crash;
  - `stop/1` ends it: SIGTERM, then SIGKILL after a grace.

  The command is the agent's settings' `command`, and there is no default: nothing runs
  Claude Code unless a machine's settings name it (`"command": "claude"`); tests give a fake
  that prints the same stream. Its `model`, `budget_usd` and `allowed` (the `atlas`
  commands, `get list set` by default) come from there too.
  """
  @behaviour AtlasRuntime.Agent

  use GenServer

  require Logger

  @grace 5_000

  @impl AtlasRuntime.Agent
  def start(turn, opts), do: GenServer.start(__MODULE__, {self(), turn, opts})

  @impl AtlasRuntime.Agent
  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "The command line for a turn: `{executable, args}` (for tests and the design)."
  def command(turn, settings) do
    allowed =
      for tool <- String.split(settings["allowed"] || "get list set"),
          do: "Bash(atlas #{tool}:*)"

    args =
      ["-p", prompt(turn), "--output-format", "stream-json", "--verbose"] ++
        ["--restricted", "--strict-mcp-config", "--tools", "Bash"] ++
        ["--allowedTools" | allowed] ++
        ["--permission-mode", "dontAsk", "--no-session-persistence"] ++
        ["--model", settings["model"] || "sonnet"] ++
        ["--max-budget-usd", to_string(settings["budget_usd"] || 0.5)] ++
        ["--append-system-prompt", rules(turn)]

    {settings["command"], args}
  end

  defp prompt(turn) do
    "You are #{turn.agent}, in a turn on #{turn.item} (turn #{turn.key}). " <>
      "Start with `atlas get #{turn.item}`: its What to do part says what is expected of you."
  end

  defp rules(turn) do
    "You act on Atlas only through the atlas commands you are allowed. Do what is " <>
      "expected of you on #{turn.item}, then end your turn with one change on it, with a " <>
      "cause that says what you did and why (`atlas set #{turn.item} … --cause \"…\"`), and stop."
  end

  @impl GenServer
  def init({turn_pid, turn, opts}) do
    settings = Keyword.get(opts, :agent, %{})
    folder = Path.join(Keyword.fetch!(opts, :turns_dir), turn.key)
    File.mkdir_p!(folder)
    {command, args} = command(turn, settings)

    # A script run by node (Claude Code's cli.js) when the settings name node, so the
    # process's PATH need not hold node either.
    {exe, args} =
      case settings["node"] do
        node when is_binary(node) ->
          {node, [command | args]}

        _ ->
          {command && (System.find_executable(command) || (File.exists?(command) && command)),
           args}
      end

    with true <- is_binary(exe) and File.exists?(exe),
         :ok <- wrapper(folder, opts) do
      # Its stdin is /dev/null (else Claude Code waits 3 s for one); exec keeps the pid.
      args = ["-c", ~s(exec "$0" "$@" < /dev/null), exe | args]

      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 65_536},
          {:args, args},
          {:cd, folder},
          {:env, port_env(environment(turn, opts, folder))}
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      log = File.open!(Path.join(folder, "stream.jsonl"), [:write, :utf8])

      {:ok, %{turn_pid: turn_pid, port: port, os_pid: os_pid, result: nil, partial: "", log: log}}
    else
      {:error, why} -> {:stop, why}
      _ -> {:stop, {:no_command, command}}
    end
  end

  @kept ~w(HOME USER LOGNAME TMPDIR LANG LC_ALL LC_CTYPE TERM)
  # What Claude Code runs by name for itself: macOS's keychain tool, for its login.
  @sys ["/usr/bin/security"]

  @doc """
  The turn's whole environment: a few names kept from the machine's (home, user, language),
  then which agent it is, the instance's settings file, no update of the build, and a PATH
  of the turn's own `bin` folder, which holds the wrapper `atlas`, and its `sys` folder,
  which holds only what Claude Code itself needs: on macOS `security`, with which it reads
  its login from the keychain (without it: "Not logged in"). The agent may not run it.
  """
  def environment(turn, opts, folder) do
    kept = for name <- @kept, value = System.get_env(name), into: %{}, do: {name, value}

    Map.merge(kept, %{
      "ATLAS_AS" => turn.agent,
      "ATLAS_ENV_FILE" => Keyword.get(opts, :env_file) || "",
      "ATLAS_NO_UPDATE" => "1",
      "PATH" => Path.join(folder, "bin") <> ":" <> Path.join(folder, "sys"),
      "SHELL" => "/bin/bash"
    })
  end

  # Every name of the machine's environment is unset but those given.
  defp port_env(env) do
    unset = for {name, _} <- System.get_env(), not Map.has_key?(env, name), do: {name, false}

    for {name, value} <- Enum.to_list(env) ++ unset,
        do: {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}
  end

  @doc """
  The turn's only `atlas`, in `<folder>/bin`: it refuses `--env`, an `ATLAS_ENV_FILE` but
  the instance's, and any command but get, list and set; else it runs the build's `atlas`
  on the instance, with the machine's PATH for itself only.
  """
  def wrapper(folder, opts) do
    file = Keyword.get(opts, :env_file)
    bin = Keyword.get(opts, :atlas_bin)

    if is_binary(file) and file != "" and is_binary(bin) do
      dir = Path.join(folder, "bin")
      File.mkdir_p!(dir)
      path = Path.join(dir, "atlas")
      File.write!(path, wrapper_script(file, Path.join(bin, "atlas"), System.get_env("PATH")))
      File.chmod!(path, 0o755)
      sys = Path.join(folder, "sys")
      File.mkdir_p!(sys)

      for tool <- @sys, File.exists?(tool) do
        link = Path.join(sys, Path.basename(tool))
        File.rm(link)
        :ok = File.ln_s(tool, link)
      end

      :ok
    else
      {:error, :no_instance}
    end
  end

  defp wrapper_script(file, atlas, path) do
    """
    #!/bin/sh
    # This turn's only atlas (IS-Atlas-18): its private instance, never another environment.
    refuse() { echo "atlas (turn): refused: $1" >&2; exit 2; }
    for arg in "$@"; do
      case "$arg" in --env|--env=*) refuse "--env; this turn works on its own instance only" ;; esac
    done
    if [ -n "${ATLAS_ENV_FILE:-}" ] && [ "$ATLAS_ENV_FILE" != #{sh(file)} ]; then
      refuse "ATLAS_ENV_FILE is not this turn's instance"
    fi
    case "${1:-}" in get|list|set) ;; *) refuse "only atlas get, list and set" ;; esac
    ATLAS_ENV_FILE=#{sh(file)} ATLAS_NO_UPDATE=1 PATH=#{sh(path)}
    export ATLAS_ENV_FILE ATLAS_NO_UPDATE PATH
    exec #{sh(atlas)} "$@"
    """
  end

  defp sh(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  @impl GenServer
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state),
    do: {:noreply, %{state | partial: state.partial <> part}}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = state.partial <> line
    IO.write(state.log, line <> "\n")
    {what, result} = event(line)
    send(state.turn_pid, {:agent, self(), {:activity, what}})
    {:noreply, %{state | partial: "", result: result || state.result}}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    send(state.turn_pid, {:agent, self(), {:ended, state.result || "it exited"}})
    {:stop, :normal, %{state | os_pid: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:exit, status}, %{state | os_pid: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  # Stopped from Runtime's side (or crashed here): the process goes too.
  @impl GenServer
  def terminate(_reason, %{os_pid: os_pid}) when is_integer(os_pid) do
    pid = Integer.to_string(os_pid)
    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)

    spawn(fn ->
      Process.sleep(@grace)
      System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
    end)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # One stream-json line: what it says it did, and its result when it is the last.
  defp event(line) do
    case JSON.decode(line) do
      {:ok, %{"type" => "result"} = event} ->
        result = first_line(event["result"] || event["subtype"] || "done")
        {"result: #{result}", result}

      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}}
      when is_list(content) ->
        {Enum.map_join(content, "; ", &part/1), nil}

      {:ok, %{"type" => type}} ->
        {type, nil}

      _ ->
        {short(line), nil}
    end
  end

  defp part(%{"type" => "tool_use", "name" => name, "input" => %{"command" => command}}),
    do: "#{name}: #{short(command)}"

  defp part(%{"type" => "tool_use", "name" => name}), do: name
  defp part(%{"type" => "text"}), do: "text"
  defp part(%{"type" => type}), do: type
  defp part(_), do: "output"

  defp first_line(text), do: text |> to_string() |> String.split("\n") |> hd() |> short()
  defp short(text), do: text |> to_string() |> String.slice(0, 120)
end
