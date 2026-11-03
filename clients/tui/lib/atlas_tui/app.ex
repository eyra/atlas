defmodule AtlasTui.App do
  @moduledoc """
  The running TUI: raw terminal input, the connection to Control, and the screen.

  - Every key goes through `AtlasTui.Model`; every message from Control too.
  - Every `reconcile_seconds` it asks Control to refresh the page from State, so a lost
    hint only delays what the screen shows.
  - A link's key opens its web address in the browser (`AtlasTui.Browser`).
  - When the connection drops it says so, retries every 2 seconds, and on return opens
    the page it was on.
  - The first `:` starts the agent (`atlas steer`, a Control client of its own) as a
    child process, and keeps it while the TUI runs. They talk in JSON lines on its stdin
    and stdout (`AtlasAgent.Steer`); its stderr goes to `steer.log` beside the
    environment's other logs.
  """

  alias AtlasTui.{Keys, Model, View}

  @escape_wait 30
  @reconnect 2_000
  @root Path.expand("../../../..", __DIR__)

  def run(env, settings) do
    with {:error, reason} <- :shell.start_interactive({:noshell, :raw}) do
      IO.puts(:stderr, "atlas: the TUI needs a terminal (#{inspect(reason)})")
      System.halt(1)
    end

    Logger.configure(level: :error)
    IO.write("\e[?1049h\e[?25l")
    parent = self()
    spawn_link(fn -> read_input(parent) end)
    AtlasTui.Resize.watch(parent)
    reconcile = settings["reconcile_seconds"] || 5
    :timer.send_interval(reconcile * 1_000, :reconcile)

    state = %{
      model: Model.new(env),
      settings: settings,
      reconcile: reconcile,
      socket: nil,
      buffer: "",
      agent: nil,
      agent_buffer: ""
    }

    state = connect(state)

    try do
      loop(draw(state))
    after
      IO.write("\e[0m\e[?25h\e[?1049l")
    end
  end

  defp read_input(parent) do
    case IO.getn(:stdio, "", 1) do
      data when is_binary(data) ->
        send(parent, {:input, data})
        read_input(parent)

      _eof ->
        send(parent, {:input, <<3>>})
    end
  end

  defp loop(state) do
    receive do
      {:input, data} ->
        {keys, rest} = Keys.parse(state.buffer <> data)
        if rest != "", do: Process.send_after(self(), {:flush, rest}, @escape_wait)
        keys(%{state | buffer: rest}, keys)

      {:flush, rest} when rest == state.buffer ->
        keys(%{state | buffer: ""}, Keys.flush(rest))

      {:flush, _old} ->
        loop(state)

      {:tcp, _socket, line} ->
        case JSON.decode(line) do
          {:ok, message} -> loop(draw(%{state | model: Model.message(state.model, message)}))
          _ -> loop(state)
        end

      {:tcp_closed, _socket} ->
        Process.send_after(self(), :reconnect, @reconnect)
        loop(draw(%{state | socket: nil, model: Model.disconnected(state.model)}))

      :resized ->
        loop(draw(state))

      :reconnect ->
        loop(draw(connect(state)))

      {port, {:data, {:eol, line}}} when port == state.agent ->
        line = state.agent_buffer <> line
        state = %{state | agent_buffer: ""}

        case JSON.decode(line) do
          {:ok, message} -> loop(draw(%{state | model: Model.agent(state.model, message)}))
          _ -> loop(state)
        end

      {port, {:data, {:noeol, part}}} when port == state.agent ->
        loop(%{state | agent_buffer: state.agent_buffer <> part})

      {port, {:exit_status, status}} when port == state.agent ->
        why = "it exited with #{status}; see #{agent_log()}"

        loop(
          draw(%{state | agent: nil, agent_buffer: "", model: Model.agent_gone(state.model, why)})
        )

      :reconcile ->
        if state.socket && state.model.connected && !Model.form(state.model) &&
             !Model.step_form(state.model),
           do: send_line(state, %{"op" => "refresh"})

        loop(state)
    end
  end

  defp keys(state, []), do: loop(draw(state))

  defp keys(state, [key | rest]) do
    {model, effects} = Model.key(state.model, key)
    state = %{state | model: model}

    if :quit in effects do
      if state.socket, do: :gen_tcp.close(state.socket)
      if state.agent, do: Port.close(state.agent)
      :ok
    else
      state =
        Enum.reduce(effects, state, fn
          {:send, message}, state ->
            send_line(state, message)
            state

          {:open_url, url}, state ->
            AtlasTui.Browser.open(url, state.settings)
            state

          {:agent, message}, state ->
            to_agent(state, message)
        end)

      keys(state, rest)
    end
  end

  # The agent, started when it is first needed.
  defp to_agent(state, message) do
    state = if state.agent, do: state, else: %{state | agent: start_agent(state.model.env)}
    Port.command(state.agent, [JSON.encode!(message), "\n"])
    state
  end

  defp start_agent(env) do
    atlas = Path.join(System.get_env("ATLAS_ROOT") || @root, "bin/atlas")

    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      {:line, 1_048_576},
      args: ["-c", ~s|exec "$0" steer --env "$1" 2>>"$2"|, atlas, env, agent_log()]
    ])
  end

  # Beside the environment's other logs (bin/atlas names their folder), else in tmp.
  defp agent_log,
    do: Path.join(System.get_env("ATLAS_TEST_ROOT") || System.tmp_dir!(), "steer.log")

  defp connect(state) do
    host = state.settings["control"]["host"] |> String.to_charlist()
    port = state.settings["control"]["port"]
    options = [:binary, packet: :line, active: true, buffer: 4_194_304]

    case :gen_tcp.connect(host, port, options, 2_000) do
      {:ok, socket} ->
        state = %{state | socket: socket}

        send_line(state, %{
          "op" => "hello",
          "env" => state.model.env,
          "client" => "tui",
          "spec" => AtlasTui.Blocks.version()
        })

        if state.model.path, do: send_line(state, %{"op" => "open", "to" => state.model.path})
        state

      {:error, _} ->
        Process.send_after(self(), :reconnect, @reconnect)
        %{state | socket: nil, model: Model.disconnected(state.model)}
    end
  end

  defp send_line(%{socket: nil}, _message), do: :ok

  defp send_line(%{socket: socket}, message),
    do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  defp draw(state) do
    {width, height} = size()
    state.model |> View.render(width, height, state.reconcile) |> View.to_ansi() |> IO.write()
    state
  end

  defp size do
    with {:ok, width} <- :io.columns(), {:ok, height} <- :io.rows() do
      {width, height}
    else
      _ -> {100, 30}
    end
  end
end
