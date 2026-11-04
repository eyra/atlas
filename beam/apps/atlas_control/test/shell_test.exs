defmodule AtlasControl.ShellTest do
  use ExUnit.Case, async: false
  alias AtlasControl.{FakeStore, Shell}

  defmodule Protocol do
    use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Blocks, channel: :control
  end

  defp description do
    Map.put(FakeStore.description(), "shell", %{
      "title" => "Private Console",
      "tabs" => [
        %{"id" => "parts", "label" => "Parts", "to" => "/k/part"},
        %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget"}
      ]
    })
  end

  setup do
    Application.put_env(:atlas_bus, :store, "shell-#{System.unique_integer([:positive])}")
    AtlasBus.drop_hints(0)
    start_supervised!(FakeStore)
    FakeStore.describe(description())
    start_supervised!({AtlasControl.Gateway, port: 0, name: :shell_gateway})
    old_timeout = Application.get_env(:atlas_control, :read_timeout_ms)
    Application.put_env(:atlas_control, :read_timeout_ms, 20)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)

      if old_timeout,
        do: Application.put_env(:atlas_control, :read_timeout_ms, old_timeout),
        else: Application.delete_env(:atlas_control, :read_timeout_ms)
    end)

    %{port: AtlasControl.Gateway.port(:shell_gateway)}
  end

  defp socket(port) do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
    on_exit(fn -> :gen_tcp.close(s) end)
    s
  end

  defp send_message(s, message), do: :gen_tcp.send(s, [JSON.encode!(message), "\n"])

  defp receive_message(s) do
    {:ok, line} = :gen_tcp.recv(s, 0, 1_000)
    JSON.decode!(line)
  end

  defp hello(s, overrides \\ %{}) do
    send_message(
      s,
      Map.merge(
        Protocol.message(:hello, :hello, env: "test", client: "test", spec: "0.14.0"),
        overrides
      )
    )
  end

  defp connected(port) do
    s = socket(port)
    hello(s)
    assert %{"op" => "welcome", "spec" => "0.14.0"} = receive_message(s)
    assert %{"op" => "page"} = receive_message(s)
    s
  end

  defp boot(s, props \\ %{}) do
    send_message(s, Protocol.message(:boot, :boot, props))
    receive_message(s)
  end

  test "native shell is bounded, configured, typed and deterministic" do
    d = description()
    assert {:ok, shell} = Shell.boot(d, nil)
    assert shell["title"] == "Private Console"
    assert Enum.map(shell["tabs"], & &1["id"]) == ["parts", "widgets"]
    assert shell["initial_to"] == "/k/part"
    refute Map.has_key?(shell, "blocks")
    refute Map.has_key?(shell, "keys")
    assert {:ok, deep} = Shell.boot(d, nil, "/k/widget/W-01/edit")
    assert deep["active_tab"] == "widgets"
    assert deep["initial_to"] == "/k/widget/W-01/edit"
    assert deep["revision"] == shell["revision"]
    assert {:ok, generic} = Shell.boot(d, nil, "/k/_/W-01")
    assert generic["initial_to"] == "/k/widget/W-01"
    assert generic["active_tab"] == "widgets"
    changed = put_in(d, ["shell", "tabs"], Enum.reverse(d["shell"]["tabs"]))
    assert {:ok, newer} = Shell.boot(changed, nil)
    refute newer["revision"] == shell["revision"]
    assert_raise ArgumentError, fn -> Protocol.message(:boot, :boot, to: 7) end
    assert_raise ArgumentError, fn -> Protocol.message(:boot, :boot, unknown: "x") end
    assert {:reply, %{effect: :complete}} = Protocol.classify(:boot, Map.put(shell, "op", "boot"))
    assert {:invalid, _} = Protocol.classify(:boot, %{"op" => "boot", "tabs" => []})
  end

  test "assigned root eligibility changes only the visible shell semantics" do
    d = description()
    d = Map.put(d, "start", %{"assigned" => %{"relation" => "checked_by"}})
    root = %{"id" => "assigned", "label" => "Assigned", "to" => "/", "assigned" => true}
    d = put_in(d, ["shell", "tabs"], [root | d["shell"]["tabs"]])
    assert {:ok, eligible} = Shell.boot(d, "member")
    assert eligible["initial_to"] == "/"
    assert eligible["active_tab"] == "assigned"
    assert {:ok, other} = Shell.boot(d, nil, "/")
    assert other["initial_to"] == "/k/part"
    refute eligible["revision"] == other["revision"]
    reordered = Map.new(Enum.reverse(Map.to_list(d)))
    assert Shell.boot(reordered, "member") == {:ok, eligible}
    duplicate = put_in(d, ["shell", "tabs"], [root, root | description()["shell"]["tabs"]])
    assert {:error, _} = Shell.boot(duplicate, nil)
  end

  test "removed indexes and unknown targets fall back; detail links remain" do
    d = put_in(description(), ["shell", "tabs"], [hd(description()["shell"]["tabs"])])

    for to <- ["/k/widget", "/", "/k/missing/X", "/unregistered"] do
      assert {:ok, shell} = Shell.boot(d, nil, to)
      assert shell["initial_to"] == "/k/part"
      assert shell["active_tab"] == "parts"
    end

    assert {:ok, detail} = Shell.boot(d, nil, "/k/widget/W-01")
    assert detail["initial_to"] == "/k/widget/W-01"
    refute Map.has_key?(detail, "active_tab")
  end

  test "invalid and unbounded configuration never becomes authoritative empty tabs" do
    for shell <- [
          nil,
          %{},
          %{"title" => "x", "tabs" => []},
          %{"title" => "x", "tabs" => List.duplicate(hd(description()["shell"]["tabs"]), 65)},
          %{"title" => String.duplicate("x", 129), "tabs" => description()["shell"]["tabs"]},
          %{"title" => "x", "tabs" => [%{"id" => "x", "label" => "X", "to" => "/k/missing"}]},
          %{"title" => "x", "tabs" => [%{"id" => "x", "label" => "X", "to" => "/"}]},
          %{"title" => "x", "tabs" => List.duplicate(hd(description()["shell"]["tabs"]), 2)}
        ] do
      assert {:error, _} = Shell.boot(Map.put(description(), "shell", shell), nil)
    end

    assert {:error, _} = Shell.boot(description(), nil, String.duplicate("x", 2_049))
  end

  test "legacy negotiation precedes boot; wrong env and old clients close", %{port: port} do
    s = socket(port)
    send_message(s, Protocol.message(:boot, :boot))
    assert %{"op" => "notice", "text" => "Say hello first."} = receive_message(s)
    hello(s)
    assert %{"op" => "welcome"} = receive_message(s)
    assert %{"op" => "page"} = receive_message(s)
    assert %{"op" => "boot", "env" => "test"} = boot(s)

    for override <- [%{"env" => "prod"}, %{"spec" => "0.1.0"}] do
      rejected = socket(port)
      hello(rejected, override)
      assert %{"op" => "bye"} = receive_message(rejected)
      assert {:error, :closed} = :gen_tcp.recv(rejected, 0, 1_000)
    end
  end

  test "boot separates queued pages and preserves the edit form", %{port: port} do
    FakeStore.put("W-01", %{"title" => "Before"})
    s = connected(port)
    send_message(s, %{"op" => "open", "to" => "/k/widget/W-01/edit"})
    send_message(s, Protocol.message(:boot, :boot, to: "/k/part"))
    assert %{"op" => "page", "path" => "/k/widget/W-01/edit"} = receive_message(s)
    shell = receive_message(s)
    assert {:reply, %{effect: :complete}} = Protocol.classify(:boot, shell)
    assert shell["initial_to"] == "/k/part"

    send_message(s, %{
      "op" => "submit",
      "endpoint" => "update",
      "params" => %{"kind" => "widget", "key" => "W-01"},
      "values" => %{"title" => "After"}
    })

    assert %{"op" => "notice"} = receive_message(s)
    assert %{"op" => "notice"} = receive_message(s)

    assert %{"op" => "page", "reason" => "stored", "path" => "/k/widget/W-01"} =
             receive_message(s)

    assert FakeStore.last_fact()["values"] == %{"title" => "After"}
  end

  test "State-resolved unprefixed detail and form links survive boot", %{port: port} do
    d =
      put_in(description(), ["entities", "another"], %{"label" => "Another", "properties" => %{}})

    FakeStore.describe(d)
    FakeStore.put("alpha", %{"name" => "Private member"}, "member")
    s = connected(port)

    for suffix <- ["", "/edit", "/delete", "/links/checked_by"] do
      target = "/k/_/alpha" <> suffix
      canonical = "/k/member/alpha" <> suffix
      send_message(s, %{"op" => "open", "to" => target})
      assert %{"op" => "page", "path" => ^canonical} = receive_message(s)
      shell = boot(s, to: target)
      assert shell["initial_to"] == canonical
      refute Map.has_key?(shell, "active_tab")
    end
  end

  test "unavailable generic lookup is a typed error rather than index fallback", %{port: port} do
    d =
      put_in(description(), ["entities", "another"], %{"label" => "Another", "properties" => %{}})

    FakeStore.describe(d)
    s = connected(port)
    FakeStore.silent_reads(["member"])
    assert {:reply, %{effect: :error}} = Protocol.classify(:boot, boot(s, to: "/k/_/alpha/edit"))
    FakeStore.silent_reads([])
    assert %{"initial_to" => "/k/part"} = boot(s, to: "/k/_/absent/edit")
  end

  test "canonical UTF8 and reserved targets round-trip within the byte limit" do
    for {char, count, tail} <- [{"é", 339, "abcd"}, {"#", 679, "a"}] do
      target = "/k/widget/" <> String.duplicate(char, count) <> tail
      assert {:ok, shell} = Shell.boot(description(), nil, target)
      assert byte_size(shell["initial_to"]) == 2_048
      assert Shell.boot(description(), nil, shell["initial_to"]) == {:ok, shell}
      assert {:error, _} = Shell.boot(description(), nil, target <> char)
    end

    target = "/k/widget/" <> String.duplicate("é", 1_019)
    assert byte_size(target) == 2_048
    assert {:error, _} = Shell.boot(description(), nil, target)
  end

  test "malformed fresh description preserves the entire editing session", %{port: port} do
    FakeStore.put("W-01", %{"title" => "Before"})
    s = connected(port)
    send_message(s, %{"op" => "open", "to" => "/k/widget/W-01/edit"})
    assert %{"op" => "page"} = receive_message(s)
    [{_, pid, _, _}] = DynamicSupervisor.which_children(AtlasControl.Sessions)
    initial = :sys.get_state(pid)

    for bad <- [
          Map.put(description(), "entities", []),
          Map.put(description(), "relations", []),
          put_in(description(), ["entities", "member"], []),
          put_in(description(), ["entities", "member", "create"], []),
          put_in(description(), ["entities", "member", "properties"], []),
          put_in(description(), ["entities", "member", "id_prefixes"], [1]),
          put_in(description(), ["relations", "checked_by", "to"], "member"),
          Map.put(description(), "start", [])
        ] do
      FakeStore.describe(bad)
      assert {:reply, %{effect: :error}} = Protocol.classify(:boot, boot(s))
      assert :sys.get_state(pid) == initial
    end

    FakeStore.describe(description())
    assert %{"op" => "boot", "initial_to" => "/k/part"} = boot(s)
    assert :sys.get_state(pid) == initial
    assert FakeStore.sent() == []
  end

  test "fresh boot reconciles and reconnects; failed description is a typed error", %{port: port} do
    s = connected(port)
    first = boot(s)
    updated = put_in(description(), ["shell", "tabs"], [hd(description()["shell"]["tabs"])])
    FakeStore.describe(updated)
    second = boot(s, to: "/k/widget")
    refute second["revision"] == first["revision"]
    assert second["initial_to"] == "/k/part"
    assert boot(connected(port)) == second
    FakeStore.silent_reads(["_description"])
    error = boot(s)
    assert {:reply, %{effect: :error}} = Protocol.classify(:boot, error)
    refute Map.has_key?(error, "tabs")
    FakeStore.silent_reads([])
    assert boot(s) == second
    assert FakeStore.sent() == []
  end
end
