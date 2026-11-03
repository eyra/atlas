defmodule AtlasTui.App do
  @moduledoc """
  The running TUI: raw terminal input, the connection to Control, and the screen.

  - Every key goes through `AtlasTui.Model`; every message from Control too.
  - Every `reconcile_seconds` it asks Control to refresh the page from State, so a lost
    hint only delays what the screen shows.
  - When the connection drops it says so, retries every 2 seconds, and on return opens
    the page it was on.
  """

  alias AtlasTui.{Keys, Model, View}

  @escape_wait 30
  @reconnect 2_000

  def run(env, settings) do
    with {:error, reason} <- :shell.start_interactive({:noshell, :raw}) do
      IO.puts(:stderr, "atlas: the TUI needs a terminal (#{inspect(reason)})")
      System.halt(1)
    end

    Logger.configure(level: :error)
    IO.write("\e[?1049h\e[?25l")
    parent = self()
    spawn_link(fn -> read_input(parent) end)
    reconcile = settings["reconcile_seconds"] || 5
    :timer.send_interval(reconcile * 1_000, :reconcile)

    state = %{
      model: Model.new(env),
      settings: settings,
      reconcile: reconcile,
      socket: nil,
      buffer: ""
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

      :reconnect ->
        loop(draw(connect(state)))

      :reconcile ->
        if state.socket && state.model.connected && !Model.form(state.model),
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
      :ok
    else
      Enum.each(effects, fn {:send, message} -> send_line(state, message) end)
      keys(state, rest)
    end
  end

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
