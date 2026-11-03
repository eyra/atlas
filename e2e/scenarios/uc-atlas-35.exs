# UC-Atlas-35: the BFF contract says which pages and endpoints Control serves
# (bff/README.md, Protocol; ADR 0002). IS-Atlas-70 pages, IS-Atlas-71 form submits,
# IS-Atlas-72 the session's other calls and the contract version in hello.
import AtlasE2E.Scenario

scenario "UC-Atlas-35: The contract says which pages and endpoints Control serves", fn ctx ->
  %{t1: t1, instance: i} = ctx

  contract =
    i.root |> Path.join("bff/targets/json/blocks.json") |> File.read!() |> JSON.decode!()

  step "blocks.json lists the pages, the form submits and every call the TUI makes", fn ->
    pages = Enum.map(contract["pages"], & &1["path"])

    for path <- ["/", "/k/:kind", "/k/:kind/new", "/k/:kind/:key", "/k/:kind/:key/edit"],
        do: path in pages || raise("blocks.json has no page #{path}: #{inspect(pages)}")

    calls = Enum.map(contract["endpoints"], &{&1["call"], &1["name"]})

    for call <- [
          {"open", "item"},
          {"submit", "create"},
          {"submit", "update"},
          {"submit", "delete"},
          {"hello", "hello"},
          {"refresh", "refresh"},
          {"page", "hint"},
          {"notice", "notice"},
          {"bye", "bye"},
          {"ask", "ask"},
          {"run", "run"},
          {"stop", "stop"}
        ],
        do: call in calls || raise("blocks.json has no endpoint #{inspect(call)}")

    update = Enum.find(contract["endpoints"], &(&1["name"] == "update"))

    update["replies"] == %{"stored" => "view model", "refused" => "view model"} ||
      raise inspect(update)
  end

  step "An older client is told it is too old, and closed; it does not break", fn ->
    port = i.settings["control"]["port"]
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
    hello = %{"op" => "hello", "env" => "test", "client" => "tui", "spec" => "0.10.0"}
    :ok = :gen_tcp.send(socket, [JSON.encode!(hello), "\n"])
    {:ok, line} = :gen_tcp.recv(socket, 0, 3_000)

    %{"op" => "bye", "text" => text} = JSON.decode!(line)

    text =~ "This client implements contract 0.10.0; Control test speaks #{contract["version"]}." ||
      raise text

    {:error, :closed} = :gen_tcp.recv(socket, 0, 3_000)
  end

  # TUI 2 is not asked to show it: by the time this runs, the scenes list is longer than
  # its screen. The agents' command line submits the same way and reads it back.
  step "Create and update submit to the contract's endpoints, from the TUI and an agent", fn ->
    press(t1, "c")
    see(t1, ~r/^ Create scene$/m)
    type(t1, "A scene of the contract")
    at = press(t1, "C-s")
    stored(t1, ~r/Scene SC-Atlas-\d+: A scene of the contract/, at)
    key = capture(t1, ~r/Scene (SC-Atlas-\d+): A scene of the contract/)

    press(t1, "u")
    see(t1, "Update #{key}")
    type(t1, " (updated)")
    at = press(t1, "C-s")
    stored(t1, "Scene #{key}: A scene of the contract (updated)", at)

    {item, _} = atlas_json(i, ["set", key, "title=A scene of the contract (by an agent)"])
    item["title"] =~ "A scene of the contract (by an agent)" || raise inspect(item)
  end
end
