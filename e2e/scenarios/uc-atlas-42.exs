# IS-Atlas-119: native boot and two Console TUIs, on private stubs.
import AtlasE2E.Scenario

scenario "UC-Atlas-42: Boot returns a native configured shell without navigating", fn ctx ->
  %{instance: i, t1: t1, t2: t2} = ctx
  Code.prepend_path(Path.join(i.root, "beam/_build/dev/lib/atlas_bff/ebin"))
  Code.prepend_path(Path.join(i.root, "beam/_build/dev/lib/atlas_bff_contract/ebin"))

  defmodule ConsoleBootProtocol do
    use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Contract, channel: :control
  end

  send_message = fn socket, message -> :gen_tcp.send(socket, [JSON.encode!(message), "\n"]) end

  receive_message = fn socket ->
    {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)
    JSON.decode!(line)
  end

  connect = fn ->
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", i.settings["control"]["port"], [
        :binary,
        packet: :line,
        active: false
      ])

    send_message.(
      socket,
      ConsoleBootProtocol.message(:hello, :hello, env: "test", client: "native", spec: "0.14.0")
    )

    %{"op" => "welcome"} = receive_message.(socket)
    # Consume the compatibility page; obtain shell metadata only from boot.
    %{"op" => "page"} = receive_message.(socket)
    socket
  end

  step "Two Console TUIs browse and the existing CLI still reads", fn ->
    see(t1, "Atlas Console · test")
    see(t2, "Atlas Console · test")
    {kinds, _} = atlas_json(i, ["help"])
    is_list(kinds) || raise inspect(kinds)
  end

  step "The real TUIs cycle Console tabs and return to Scenes", fn ->
    for t <- [t1, t2] do
      see(t, "▸ Scenes")
      press(t, "Tab")
      see(t, "▸ Open work")
      see_list(t, "Open work")
      ready(t)
      press(t, "BTab")
      see(t, "▸ Scenes")
      see_list(t, "Scenes")
      ready(t)
    end
  end

  socket = connect.()

  try do
    step "Typed boot returns only the configured native tab model", fn ->
      send_message.(socket, ConsoleBootProtocol.message(:boot, :boot, to: "/k/scene"))
      shell = receive_message.(socket)
      {:reply, %{name: :shell, effect: :complete}} = ConsoleBootProtocol.classify(:boot, shell)
      shell["title"] == "Atlas Console" || raise inspect(shell)
      shell["env"] == "test" || raise inspect(shell)
      Enum.map(shell["tabs"], & &1["id"]) == ["scenes", "open-work"] || raise inspect(shell)
      shell["initial_to"] == "/k/scene" || raise inspect(shell)
      shell["active_tab"] == "scenes" || raise inspect(shell)
      Map.has_key?(shell, "blocks") && raise "boot returned page blocks"
      Process.put(:console_shell, shell)
    end

    step "Queued pages stay distinct and boot preserves the editing route", fn ->
      send_message.(socket, %{"op" => "open", "to" => "/k/scene/new"})
      send_message.(socket, ConsoleBootProtocol.message(:boot, :boot, to: "/k/assignment"))
      %{"op" => "page", "path" => "/k/scene/new"} = receive_message.(socket)
      %{"op" => "boot", "active_tab" => "open-work"} = receive_message.(socket)
      send_message.(socket, %{"op" => "refresh"})
      {:error, :timeout} = :gen_tcp.recv(socket, 0, 200)
    end

    step "Boot retains a generic unprefixed detail resolved by ordinary State routing", fn ->
      send_message.(socket, %{"op" => "open", "to" => "/k/_/melle/edit"})
      %{"op" => "page", "path" => "/k/person/melle/edit"} = receive_message.(socket)
      send_message.(socket, ConsoleBootProtocol.message(:boot, :boot, to: "/k/_/melle/edit"))
      %{"op" => "boot", "initial_to" => "/k/person/melle/edit"} = receive_message.(socket)
    end

    step "A valid component association target remains canonical", fn ->
      {scene, _} = atlas_json(i, ["put", "scene", "--title", "Private component boot proof"])
      key = scene["key"]
      is_binary(key) || raise inspect(scene)

      send_message.(
        socket,
        ConsoleBootProtocol.message(:boot, :boot, to: "/k/scene/#{key}/links/assigned_to")
      )

      shell = receive_message.(socket)
      shell["initial_to"] == "/k/assignment/AS-#{key}/links/assigned_to" || raise inspect(shell)
    end

    step "Reconciliation and reconnect return the same shell revision", fn ->
      send_message.(socket, ConsoleBootProtocol.message(:boot, :boot, to: "/k/scene"))
      Process.get(:console_shell) == receive_message.(socket) || raise "shell revision drifted"
      other = connect.()

      try do
        send_message.(other, ConsoleBootProtocol.message(:boot, :boot, to: "/k/scene"))
        Process.get(:console_shell) == receive_message.(other) || raise "reconnect shell differs"
      after
        :gen_tcp.close(other)
      end

      see(t1, "Atlas Console · test")
      see(t2, "Atlas Console · test")
    end
  after
    :gen_tcp.close(socket)
  end
end
