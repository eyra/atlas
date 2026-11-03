defmodule AtlasControl.Gateway do
  @moduledoc """
  Where clients connect: a TCP listener on this environment's Control address. Each
  connection gets its own `AtlasControl.Session`.
  """
  use GenServer

  require Logger

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The port it listens on (useful when started on port 0)."
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    {:ok, ip} =
      opts |> Keyword.get(:host, "127.0.0.1") |> String.to_charlist() |> :inet.parse_address()

    {:ok, listen} =
      :gen_tcp.listen(Keyword.fetch!(opts, :port), [
        :binary,
        ip: ip,
        packet: :line,
        buffer: 4_194_304,
        active: false,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen)

    Logger.info(
      "Control #{AtlasBus.environment()} listens on #{Keyword.get(opts, :host, "127.0.0.1")}:#{port}"
    )

    acceptor = spawn_link(fn -> accept(listen) end)
    {:ok, %{listen: listen, port: port, acceptor: acceptor}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)

    {:ok, pid} =
      DynamicSupervisor.start_child(AtlasControl.Sessions, {AtlasControl.Session, socket})

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    accept(listen)
  end
end
