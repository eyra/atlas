defmodule AtlasControl.SessionTest do
  use ExUnit.Case, async: false

  alias AtlasControl.FakeStore

  setup do
    Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")
    AtlasBus.drop_hints(0)
    start_supervised!(FakeStore)
    start_supervised!({AtlasControl.Gateway, port: 0, name: :gateway})
    %{port: AtlasControl.Gateway.port(:gateway)}
  end

  defp client(port, env \\ "test") do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [
        :binary,
        packet: :line,
        active: false,
        buffer: 4_194_304
      ])

    put(socket, %{"op" => "hello", "env" => env, "client" => "test"})
    socket
  end

  defp put(socket, message), do: :ok = :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  # The next message with this op, skipping others; nil when none comes.
  defp next(socket, op, timeout \\ 1_000) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        message = JSON.decode!(line)
        if message["op"] == op, do: message, else: next(socket, op, timeout)

      {:error, :timeout} ->
        nil
    end
  end

  defp rows(page),
    do: page["blocks"] |> hd() |> get_in(["props", "rows"]) |> Enum.map(& &1["label"])

  test "a client sees the top list at once", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    c = client(port)
    assert %{"env" => "test", "spec" => "0.1.0"} = next(c, "welcome")
    assert %{"path" => "/", "title" => "Widgets", "reason" => "open"} = page = next(c, "page")
    assert rows(page) == ["One"]
  end

  test "a change shows once it is stored, and reaches a second client as a hint", %{port: port} do
    a = client(port)
    b = client(port)
    next(a, "page")
    next(b, "page")

    put(a, %{"op" => "open", "to" => "/k/widget/new"})
    assert %{"title" => "New widget"} = next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"_key" => "W-1", "title" => "One", "done" => "true"}
    })

    assert %{"tone" => "pending"} = next(a, "notice")
    assert %{"tone" => "ok", "text" => "Stored by State (position 1)."} = next(a, "notice")
    assert %{"path" => "/k/widget/W-1", "reason" => "stored", "position" => 1} = next(a, "page")

    assert %{"reason" => "hint", "position" => 1} = page = next(b, "page")
    assert rows(page) == ["One"]
  end

  test "a lost hint only delays: the client's reconcile finds the change", %{port: port} do
    a = client(port)
    b = client(port)
    next(a, "page")
    next(b, "page")
    :ok = AtlasBus.drop_hints(1)

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"_key" => "W-1", "title" => "One"}
    })

    assert %{"reason" => "stored"} = next(a, "page")
    assert next(b, "page", 300) == nil

    put(b, %{"op" => "refresh"})
    assert %{"reason" => "reconcile"} = page = next(b, "page")
    assert rows(page) == ["One"]
  end

  test "a refused change shows the form again, with what was typed and why", %{port: port} do
    a = client(port)
    next(a, "page")
    put(a, %{"op" => "open", "to" => "/k/widget/new"})
    next(a, "page")

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"_key" => "W-1", "title" => ""}
    })

    assert %{"tone" => "pending"} = next(a, "notice")
    assert %{"tone" => "error"} = next(a, "notice")

    assert %{"reason" => "refused", "blocks" => [%{"type" => "form", "props" => form}]} =
             next(a, "page")

    assert form["errors"] == ["title is required"]
    assert Enum.find(form["inputs"], &(&1["name"] == "_key"))["value"] == "W-1"
  end

  test "change and delete name the version they were made from", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "open", "to" => "/k/widget/W-1/edit"})
    assert %{"blocks" => [%{"type" => "form"}]} = next(a, "page")
    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/edit", "values" => %{"title" => "Uno"}})
    assert %{"path" => "/k/widget/W-1", "reason" => "stored"} = page = next(a, "page")
    assert page["blocks"] |> hd() |> get_in(["props", "title"]) == "Widget W-1: Uno"

    put(a, %{"op" => "open", "to" => "/k/widget/W-1/delete"})
    assert %{"blocks" => [%{"type" => "confirm"}]} = next(a, "page")
    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/delete", "values" => %{}})
    assert %{"path" => "/k/widget", "reason" => "stored"} = page = next(a, "page")
    assert rows(page) == []
  end

  test "a fact with parts under it is not deleted", %{port: port} do
    FakeStore.put("W-1", %{"title" => "One"})
    FakeStore.link("P-1", "W-1")
    a = client(port)
    next(a, "page")

    put(a, %{"op" => "submit", "to" => "/k/widget/W-1/delete", "values" => %{}})
    assert %{"blocks" => [%{"type" => "confirm", "props" => props}]} = next(a, "page")
    assert props["text"] =~ "still has 1 parts"
    assert next(a, "notice", 200) == nil
  end

  test "a client of the other environment is sent away", %{port: port} do
    c = client(port, "prod")
    assert %{"op" => "bye", "text" => text} = JSON.decode!(elem(:gen_tcp.recv(c, 0, 1_000), 1))
    assert text =~ "does not serve \"prod\""
    assert {:error, :closed} = :gen_tcp.recv(c, 0, 1_000)
  end

  @tag timeout: 15_000
  test "a fact without an answer is sent again with the same id", %{port: port} do
    a = client(port)
    next(a, "page")
    FakeStore.silent(true)

    put(a, %{
      "op" => "submit",
      "to" => "/k/widget/new",
      "values" => %{"_key" => "W-1", "title" => "One"}
    })

    assert %{"tone" => "pending"} = next(a, "notice")
    FakeStore.silent(false)

    assert %{"tone" => "pending", "text" => "No answer from State yet; sent again."} =
             next(a, "notice", 7_000)

    assert %{"tone" => "ok"} = next(a, "notice")
  end
end
