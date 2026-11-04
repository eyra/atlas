defmodule AtlasBus.LinkTest do
  use ExUnit.Case, async: false
  alias AtlasBus.{Envelope, Link}

  setup do
    Application.put_env(:atlas_bus, :environment, "test")

    start_supervised!(
      {Link.Server, %{"port" => 0, "tokens" => %{"laptop" => "private-test-token"}}}
    )

    %{port: Link.Server.port()}
  end

  defp connect(port, more \\ %{}) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])

    frame =
      Map.merge(
        %{"environment" => "test", "machine" => "laptop", "token" => "private-test-token"},
        more
      )

    :ok = :gen_tcp.send(socket, Link.encode("hello", frame))
    socket
  end

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
    JSON.decode!(line)
  end

  defp eventually(fun, n \\ 100) do
    cond do
      fun.() ->
        :ok

      n == 0 ->
        flunk("Bus did not reconcile")

      true ->
        Process.sleep(10)
        eventually(fun, n - 1)
    end
  end

  test "hello binds the token to both environment and machine", %{port: port} do
    for more <- [%{"token" => "wrong"}, %{"environment" => "prod"}, %{"machine" => "other"}] do
      s = connect(port, more)
      assert recv(s)["op"] == "refused"
      assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}
      :gen_tcp.close(s)
    end
  end

  test "endpoint impersonation and forged acknowledgements close the link", %{port: port} do
    for name <- ["state", "flow", "runtime@other", "runtime@laptop-other"] do
      s = connect(port)
      assert recv(s)["op"] == "welcome"
      :gen_tcp.send(s, Link.encode("attach", %{"endpoint" => name}))
      assert recv(s)["op"] == "refused"
      :gen_tcp.close(s)
    end

    s = connect(port)
    recv(s)
    :gen_tcp.send(s, Link.encode("attach", %{"endpoint" => "runtime@laptop"}))

    :gen_tcp.send(
      s,
      Link.encode("send", %{
        "endpoint" => "runtime@laptop",
        "envelope" => Link.envelope_out(Envelope.new("stored", "parcel")),
        "content" => %{}
      })
    )

    assert recv(s)["op"] == "refused"
    :gen_tcp.close(s)
  end

  test "stopping or crashing the listener closes its connections and registrations", %{port: port} do
    for how <- [:stop, :kill] do
      s = connect(if(how == :stop, do: port, else: Link.Server.port()))
      recv(s)
      name = "runtime@laptop/owned-by-listener"
      :gen_tcp.send(s, Link.encode("attach", %{"endpoint" => name}))
      eventually(fn -> Registry.lookup(AtlasBus.Endpoints, name) != [] end)

      case how do
        :stop ->
          stop_supervised!(Link.Server)

          start_supervised!(
            {Link.Server, %{"port" => 0, "tokens" => %{"laptop" => "private-test-token"}}}
          )

        :kill ->
          Process.exit(Process.whereis(Link.Server), :kill)
      end

      assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}
      eventually(fn -> Registry.lookup(AtlasBus.Endpoints, name) == [] end)
      :gen_tcp.close(s)
    end
  end

  test "envelopes cross both ways with the registered sender; disconnect removes endpoints", %{
    port: port
  } do
    store = "link-test-store"
    Application.put_env(:atlas_bus, :store, store)
    :ok = AtlasBus.attach(store)
    s = connect(port)
    assert recv(s)["op"] == "welcome"
    name = "runtime@laptop/T-1"
    :gen_tcp.send(s, Link.encode("attach", %{"endpoint" => name}))
    :gen_tcp.send(s, Link.encode("listen", %{"endpoint" => name, "kind" => "parcel"}))
    envelope = %{Envelope.new("read", "parcel") | sender: "state"}

    :gen_tcp.send(
      s,
      Link.encode("send", %{
        "endpoint" => name,
        "envelope" => Link.envelope_out(envelope),
        "content" => %{"key" => "P-1"}
      })
    )

    assert_receive {:atlas_bus, received, %{"key" => "P-1"}}, 1_000
    assert received.sender == name
    AtlasBus.send(Envelope.reply(received, "answer"), %{"value" => 42})
    assert %{"op" => "deliver", "endpoint" => ^name, "content" => %{"value" => 42}} = recv(s)
    AtlasBus.send(%{Envelope.new("stored", "parcel") | address: nil}, %{"key" => "P-1"})
    assert recv(s)["envelope"]["class"] == "stored"
    :gen_tcp.close(s)
    eventually(fn -> Registry.lookup(AtlasBus.Endpoints, name) == [] end)
    assert Registry.lookup(AtlasBus.Listeners, "parcel") == []
  end
end
