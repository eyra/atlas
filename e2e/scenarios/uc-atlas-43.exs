# IS-Atlas-120: real Control projections beside unchanged legacy TUIs, private stubs only.
import AtlasE2E.Scenario

scenario "UC-Atlas-43: Console actions are scoped typed blocks and share ordinary authority",
         fn ctx ->
           %{instance: i, t1: t1, t2: t2} = ctx

           for app <- ["atlas_bff", "atlas_bff_contract"],
               do: Code.prepend_path(Path.join(i.root, "beam/_build/dev/lib/#{app}/ebin"))

           defmodule ConsoleActionProtocol do
             use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Blocks, channel: :control
           end

           send_message = fn s, message -> :gen_tcp.send(s, [JSON.encode!(message), "\n"]) end

           read = fn s ->
             {:ok, line} = :gen_tcp.recv(s, 0, 10_000)
             JSON.decode!(line)
           end

           page = fn s ->
             Stream.repeatedly(fn -> read.(s) end)
             |> Enum.find(&(&1["op"] == "page"))
           end

           {:ok, s} =
             :gen_tcp.connect(~c"127.0.0.1", i.settings["control"]["port"], [
               :binary,
               packet: :line,
               active: false,
               buffer: 4_194_304
             ])

           try do
             step "Console acknowledges a real projection while legacy TUIs keep browsing", fn ->
               send_message.(
                 s,
                 ConsoleActionProtocol.message(:hello, :hello,
                   env: "test",
                   client: "native",
                   spec: "0.14.0",
                   surface: "console"
                 )
               )

               %{"op" => "welcome", "surface" => "console"} = read.(s)
               {:ok, _} = AtlasBFFContract.Console.compile(page.(s))
               see(t1, "Atlas · test")
               see(t2, "Atlas · test")
             end

             step "Declared keys bind the same scoped blocks grouped by legend markup", fn ->
               send_message.(s, %{"op" => "open", "to" => "/k/scene"})
               p = page.(s)
               {:ok, projection} = AtlasBFFContract.Console.compile(p)
               current = %{path: p["path"], context: "browse", generation: 1}
               {:ok, bindings} = AtlasBFFContract.Console.bindings(projection, current)

               bindings["Tab"]["props"]["operation"] == %{"name" => "tab_next"} ||
                 raise "missing typed tab action"

               {:ok, event} = AtlasBFFContract.Console.capture(projection, "Tab", current)
               Process.put(:console_action_before, {projection, current, event})

               Enum.any?(projection.groups, &(&1["props"]["context"] == "browse")) ||
                 raise "missing legend"
             end

             step "Reconciliation replaces the projection and rejects captured stale actions",
                  fn ->
                    send_message.(s, %{"op" => "refresh"})
                    {:ok, next} = AtlasBFFContract.Console.compile(page.(s))
                    {previous, current, event} = Process.get(:console_action_before)
                    previous.revision != next.revision || raise "revision was reused"

                    {:error, :stale_or_unavailable_action} =
                      AtlasBFFContract.Console.resolve(next, event, current)
                  end

             step "A real projected form submits through the existing typed endpoint", fn ->
               send_message.(s, %{"op" => "open", "to" => "/k/scene/new"})
               p = page.(s)
               {:ok, index} = AtlasBFFContract.Console.compile(p)
               current = %{path: p["path"], context: "form", generation: 2}
               {:ok, bindings} = AtlasBFFContract.Console.bindings(index, current)
               action = bindings["Ctrl+S"]
               action["props"]["operation"] == %{"name" => "submit"} || raise "missing submit"
               form = Enum.find(p["blocks"], &(&1["id"] == action["props"]["scope"]["on"]))
               %{"endpoint" => "create", "params" => params} = form["props"]["submit_to"]
               to = ConsoleActionProtocol.endpoint_path(:submit, :create, params)

               send_message.(s, %{
                 "op" => "submit",
                 "to" => to,
                 "values" => %{
                   "title" => "Private Console action proof",
                   "description" => "Synthetic action contract test"
                 }
               })

               stored = page.(s)
               stored["reason"] == "stored" || raise inspect(stored)
               {:ok, _} = AtlasBFFContract.Console.compile(stored)
               see(t1, "Atlas · test")
               see(t2, "Atlas · test")
             end
           after
             :gen_tcp.close(s)
           end
         end
