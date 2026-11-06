# MIX_ENV=test mix run integration/worker_control.exs
# Real Control sockets, Bus, State and private durable synthetic storage; no harness.
ExUnit.start(seed: 0)

defmodule WorkerControlTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasState.{GuidanceStore, Rela}
  alias AtlasBFFContract.Workers.Protocol, as: Wire
  @moduletag :tmp_dir

  defp description do
    roles = %{
      "execution" =>
        ~w(environment worker turn attempt machine harness harness_version configured_model reported_model capability_version queued_input durable_accept_query consumption_evidence recorded_at recorded_position),
      "interaction" =>
        ~w(environment actor client_key body body_digest worker turn attempt mode execution cause recorded_at recorded_position),
      "receipt" =>
        ~w(environment interaction worker turn attempt execution stage evidence_id admission_id consumption_id reason writer cause recorded_at recorded_position)
    }

    mapping =
      Map.new(roles, fn {role, fields} ->
        {role, %{"kind" => "synthetic_" <> role, "fields" => Map.new(fields, &{&1, &1})}}
      end)

    ordinary = %{
      "reader" => {"readers", "H-", ~w(name)},
      "operator" => {"operators", "W-", ~w(name)},
      "run" => {"runs", "R-", ~w(host fence state activity lease outcome)},
      "ticket" => {"tickets", "T-", ~w(title step handover)}
    }

    entities =
      Map.new(ordinary, fn {kind, {plural, prefix, fields}} ->
        {kind,
         %{
           "plural" => plural,
           "id_prefix" => prefix,
           "properties" => Map.new(fields, &{&1, %{"type" => "string"}})
         }}
      end)

    entities =
      Enum.reduce(mapping, entities, fn {role, spec}, acc ->
        properties =
          Map.new(spec["fields"], fn {slot, field} ->
            type =
              cond do
                slot in ~w(queued_input durable_accept_query consumption_evidence) -> "boolean"
                slot == "recorded_position" -> "integer"
                true -> "string"
              end

            {field, %{"type" => type}}
          end)

        Map.put(acc, spec["kind"], %{
          "plural" => role <> "s",
          "properties" => properties,
          "top" => false,
          "by_hand" => false
        })
      end)

    %{
      "entities" => entities,
      "shell" => %{
        "title" => "Private workers",
        "tabs" => [%{"id" => "workers", "label" => "Workers", "to" => "/workers"}]
      },
      "relations" => %{
        "performer" => %{"from" => ["run"], "to" => ["operator"]},
        "task" => %{"from" => ["run"], "to" => ["ticket"]},
        "owner" => %{"from" => ["ticket"], "to" => ["operator"]}
      },
      "guidance" =>
        Map.put(mapping, "control", %{
          "read" => %{"actors" => ["H-1", "H-2"]},
          "submit" => %{"actors" => ["H-1"]}
        }),
      "runtime" => %{
        "turn" => %{
          "kind" => "run",
          "machine" => "host",
          "attempt" => "fence",
          "by" => "performer",
          "on" => "task",
          "state" => "state",
          "running" => "running",
          "ended" => "ended",
          "lease" => "lease",
          "activity" => "activity",
          "outcome" => "outcome"
        }
      },
      "flows" => %{
        "work" => %{
          "kinds" => ["ticket"],
          "state_field" => "step",
          "handover_field" => "handover",
          "owner_relation" => "owner",
          "field" => "title",
          "states" => [%{"name" => "work", "owner" => "W-1", "expected" => "work"}]
        }
      }
    }
  end

  setup %{tmp_dir: dir} = context do
    previous_store = Application.get_env(:atlas_bus, :store)
    previous_timeout = Application.get_env(:atlas_control, :read_timeout_ms)
    Application.put_env(:atlas_bus, :store, "worker-proof-#{System.unique_integer([:positive])}")
    Application.put_env(:atlas_control, :read_timeout_ms, 100)
    {:ok, backend} = GuidanceStore.start(Path.join(dir, "facts.json"), description())
    rela = {GuidanceStore, backend}

    for actor <- ["H-1", "H-2", "H-3"] do
      {:ok, []} = Rela.create(rela, "readers", actor, %{"name" => actor}, %{})
    end

    {:ok, []} = Rela.create(rela, "operators", "W-1", %{"name" => "Worker"}, %{})

    {:ok, []} =
      Rela.create(rela, "tickets", "T-1", %{"title" => "Private task", "step" => "work"}, %{
        "owner" => {"operator", ["W-1"]}
      })

    {:ok, []} =
      Rela.create(
        rela,
        "runs",
        "R-1",
        %{
          "host" => "box",
          "fence" => "attempt-1",
          "state" => "running",
          "activity" => "private synthetic activity",
          "lease" => DateTime.utc_now() |> DateTime.add(600) |> DateTime.to_iso8601()
        },
        %{"performer" => {"operator", ["W-1"]}, "task" => {"ticket", ["T-1"]}}
      )

    start_supervised!({AtlasState.Server, rela: rela, data_dir: dir})

    {:stored, %{"fact" => execution}} =
      bus("runtime@box", "synthetic_execution", %{
        "op" => "register_execution",
        "values" => %{
          "worker" => "W-1",
          "turn" => "R-1",
          "attempt" => "attempt-1",
          "machine" => "box",
          "harness" => "private-fake",
          "harness_version" => "1",
          "configured_model" => "synthetic",
          "capability_version" => "1",
          "queued_input" => context[:unsupported] != true,
          "durable_accept_query" => true,
          "consumption_evidence" => true
        }
      })

    start_supervised!({AtlasControl.Gateway, port: 0, name: :worker_proof_gateway})
    port = AtlasControl.Gateway.port(:worker_proof_gateway)

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)

      Application.put_env(:atlas_bus, :store, previous_store)

      if previous_timeout,
        do: Application.put_env(:atlas_control, :read_timeout_ms, previous_timeout),
        else: Application.delete_env(:atlas_control, :read_timeout_ms)
    end)

    %{rela: rela, backend: backend, execution: execution, port: port}
  end

  defp target,
    do: %{
      "worker" => %{"environment" => "test", "machine" => "box", "worker" => "W-1"},
      "turn" => "R-1",
      "attempt" => "attempt-1"
    }

  defp guidance(key \\ "same-key"),
    do: %{
      "client_key" => key,
      "body" => "/stop is literal guidance, not a machine control",
      "cause" => "private proof"
    }

  defp bus(endpoint, kind, content) do
    Task.async(fn ->
      :ok = AtlasBus.attach(endpoint)

      try do
        envelope = Envelope.new("fact", kind)
        :ok = AtlasBus.send(envelope, content)

        receive do
          {:atlas_bus, %Envelope{id: id, class: class}, answer} when id == envelope.id ->
            {String.to_existing_atom(class), answer}
        after
          2000 -> flunk("State did not reply")
        end
      after
        Registry.unregister(AtlasBus.Endpoints, endpoint)
      end
    end)
    |> Task.await()
  end

  defp connect(port, actor \\ "H-1") do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [
        :binary,
        packet: :line,
        active: false,
        buffer: 4_194_304
      ])

    send_message(socket, %{
      "op" => "hello",
      "env" => "test",
      "client" => "private-proof",
      "as" => actor,
      "spec" => AtlasControl.Blocks.version()
    })

    assert %{"op" => "welcome"} = next(socket, &(&1["op"] == "welcome"))
    next(socket, &(&1["op"] == "page"))
    socket
  end

  defp send_message(socket, message), do: :gen_tcp.send(socket, [JSON.encode!(message), "\n"])

  defp next(socket, predicate) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, line} ->
        message = JSON.decode!(line)
        if predicate.(message), do: message, else: next(socket, predicate)

      other ->
        flunk("Control socket failed: #{inspect(other)}")
    end
  end

  defp request(socket, operation, props \\ %{}) do
    id = "request-#{System.unique_integer([:positive])}"
    send_message(socket, Wire.request(operation, Map.put(props, "id", id)))
    reply = next(socket, &(&1["id"] == id))
    assert {:ok, variant, ^reply} = Wire.decode_reply(operation, reply)
    {variant, reply}
  end

  test "two real clients share stored guidance and recover exact same-key submission after closure",
       c do
    a = connect(c.port)
    b = connect(c.port, "H-2")

    on_exit(fn ->
      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end)

    assert {:result,
            %{"workers" => [%{"execution" => execution, "guidance" => %{"available" => true}}]}} =
             request(a, :worker_overview)

    assert execution == target()
    send_message(a, %{"op" => "open", "to" => "/workers/box/W-1/R-1/attempt-1"})
    assert %{"title" => "Worker W-1"} = next(a, &(&1["op"] == "page"))
    props = %{"execution" => target(), "guidance" => guidance()}
    assert {:result, %{"interaction" => interaction}} = request(a, :worker_submit, props)
    assert interaction["projection"]["proven"] == "queued"
    assert interaction["actor"] == "H-1"
    assert interaction["body"] == guidance()["body"]

    assert {:result, %{"interactions" => [^interaction]}} =
             request(b, :worker_history, %{"execution" => target()})

    assert {:result, %{"interaction" => ^interaction}} = request(a, :worker_submit, props)

    assert {:error, %{"error" => %{"code" => "immutable_conflict"}}} =
             request(a, :worker_submit, put_in(props, ["guidance", "body"], "different"))

    {:ok, []} = Rela.change(c.rela, "runs", "R-1", %{"state" => "ended"}, nil, %{})

    assert {:result, %{"found" => true, "interaction" => ^interaction}} =
             request(a, :worker_query, %{"execution" => target(), "client_key" => "same-key"})

    assert {:result, %{"interaction" => ^interaction}} = request(a, :worker_submit, props)

    assert {:error, %{"error" => %{"code" => "stale_execution"}}} =
             request(a, :worker_submit, %{props | "guidance" => guidance("new-key")})

    IO.puts(
      "SMOKE two-client durable history, literal guidance, duplicate/conflict handling and closed-turn lost-reply recovery passed"
    )
  end

  test "foreign identities, missing attempts, actor injection and protocol versions cannot submit",
       c do
    a = connect(c.port)
    denied = connect(c.port, "W-1")

    on_exit(fn ->
      :gen_tcp.close(a)
      :gen_tcp.close(denied)
    end)

    props = %{"execution" => target(), "guidance" => guidance()}

    assert {:error, %{"error" => %{"code" => "forbidden"}}} =
             request(denied, :worker_submit, props)

    assert {:error, %{"error" => %{"code" => "invalid_target"}}} =
             request(
               a,
               :worker_submit,
               put_in(props, ["execution", "worker", "environment"], "foreign")
             )

    assert {:error, %{"error" => %{"code" => "invalid_target"}}} =
             request(
               a,
               :worker_submit,
               update_in(props, ["execution"], &Map.delete(&1, "attempt"))
             )

    for change <- [%{"actor" => "H-2"}, %{"version" => "future"}] do
      message = Wire.request(:worker_submit, Map.put(props, "id", "invalid")) |> Map.merge(change)
      send_message(a, message)
      assert %{"error" => %{"code" => "invalid_request"}} = next(a, &(&1["id"] == "invalid"))
    end

    assert {:result, %{"interactions" => []}} =
             request(a, :worker_history, %{"execution" => target()})
  end

  test "receipts retain evidence and cursor cannot cross viewer or execution", c do
    a = connect(c.port)
    b = connect(c.port, "H-2")

    on_exit(fn ->
      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end)

    assert {:result, %{"interaction" => interaction}} =
             request(a, :worker_submit, %{"execution" => target(), "guidance" => guidance()})

    values =
      Map.take(interaction, ~w(worker turn attempt execution))
      |> Map.merge(%{
        "interaction" => interaction["key"],
        "stage" => "delivered",
        "evidence_id" => "proof-1",
        "cause" => "private harness proof",
        "admission_id" => "admission-1"
      })

    assert {:stored, _} =
             bus("runtime@box", "synthetic_receipt", %{
               "op" => "record_receipt",
               "values" => values
             })

    assert {:result, %{"receipts" => [%{"admission_id" => "admission-1"}], "cursor" => cursor}} =
             request(a, :worker_receipts, %{
               "execution" => target(),
               "interaction" => interaction["key"]
             })

    assert {:error, %{"error" => %{"code" => "invalid_cursor"}}} =
             request(b, :worker_receipts, %{
               "execution" => target(),
               "interaction" => interaction["key"],
               "cursor" => cursor
             })

    assert {:result, %{"receipts" => [], "more" => false}} =
             request(a, :worker_receipts, %{
               "execution" => target(),
               "interaction" => interaction["key"],
               "cursor" => cursor
             })

    :gen_tcp.close(a)
    reconnected = connect(c.port)
    on_exit(fn -> :gen_tcp.close(reconnected) end)

    assert {:result,
            %{"found" => true, "interaction" => %{"projection" => %{"proven" => "delivered"}}}} =
             request(reconnected, :worker_query, %{
               "execution" => target(),
               "client_key" => "same-key"
             })

    IO.puts("SMOKE real Control reconnect, receipt projection and scoped cursor passed")
  end

  test "named read grants never imply submit or same-kind access", c do
    reader = connect(c.port, "H-2")
    ungranted = connect(c.port, "H-3")

    on_exit(fn ->
      :gen_tcp.close(reader)
      :gen_tcp.close(ungranted)
    end)

    assert {:result,
            %{"workers" => [%{"guidance" => %{"available" => false, "reason" => "forbidden"}}]}} =
             request(reader, :worker_overview)

    assert {:error, %{"error" => %{"code" => "forbidden"}}} =
             request(reader, :worker_submit, %{"execution" => target(), "guidance" => guidance()})

    assert {:error, %{"error" => %{"code" => "forbidden"}}} = request(ungranted, :worker_overview)
  end

  @tag unsupported: true
  test "unsupported adapters expose a view but no send action or interaction", c do
    a = connect(c.port)
    on_exit(fn -> :gen_tcp.close(a) end)

    assert {:result,
            %{"view" => %{"guidance" => %{"available" => false, "reason" => "unsupported"}}}} =
             request(a, :worker_inspect, %{"execution" => target()})

    assert {:error, %{"error" => %{"code" => "unsupported"}}} =
             request(a, :worker_submit, %{"execution" => target(), "guidance" => guidance()})

    assert {:ok, []} = Rela.list(c.rela, "interactions")
  end

  test "a committed write with a lost acknowledgement is unknown then recovered without replay",
       c do
    a = connect(c.port)

    on_exit(fn ->
      :gen_tcp.close(a)
      send(c.backend, :release_commit)
    end)

    GuidanceStore.barrier(c.backend, self())

    send_message(
      a,
      Wire.request(:worker_submit, %{
        "id" => "lost",
        "execution" => target(),
        "guidance" => guidance()
      })
    )

    assert_receive {:committed, backend, key}, 2000

    assert %{"error" => %{"code" => "outcome_unknown", "retryable" => false}} =
             next(a, &(&1["id"] == "lost"))

    send(backend, :release_commit)

    assert {:result, %{"found" => true, "interaction" => %{"key" => ^key}}} =
             request(a, :worker_query, %{"execution" => target(), "client_key" => "same-key"})

    assert {:ok, [%{key: ^key}]} = Rela.list(c.rela, "interactions")

    IO.puts(
      "SMOKE actual post-commit lost acknowledgement returns unknown; exact-key query recovers one durable interaction"
    )
  end

  test "handover and replacement cannot transfer guidance authority", c do
    a = connect(c.port)
    on_exit(fn -> :gen_tcp.close(a) end)
    {:ok, []} = Rela.change(c.rela, "tickets", "T-1", %{"handover" => "pending"}, nil, %{})

    assert {:error, %{"error" => %{"code" => "stale_execution"}}} =
             request(a, :worker_submit, %{"execution" => target(), "guidance" => guidance()})

    {:ok, []} = Rela.change(c.rela, "runs", "R-1", %{"fence" => "replacement"}, nil, %{})

    assert {:error, %{"error" => %{"code" => "stale_execution"}}} =
             request(a, :worker_inspect, %{"execution" => target()})

    assert {:ok, []} = Rela.list(c.rela, "interactions")
  end

  test "generic guidance form carries stable identity and writes literal input", c do
    a = connect(c.port)
    on_exit(fn -> :gen_tcp.close(a) end)
    send_message(a, %{"op" => "open", "to" => "/workers/box/W-1/R-1/attempt-1/guidance"})
    form_page = next(a, &(&1["op"] == "page"))
    [%{"type" => "form", "props" => form}] = form_page["blocks"]
    key = Enum.find(form["inputs"], &(&1["name"] == "client_key"))["value"]
    call = form["submit_to"]

    send_message(
      a,
      Map.merge(call, %{
        "op" => "submit",
        "values" => %{guidance(key) | "body" => "/stop remains text"}
      })
    )

    assert %{"reason" => "stored", "title" => "Worker W-1"} = next(a, &(&1["op"] == "page"))

    assert {:result, %{"found" => true, "interaction" => %{"body" => "/stop remains text"}}} =
             request(a, :worker_query, %{"execution" => target(), "client_key" => key})
  end

  test "worker boot targets remain exact and history pages advance without skipping new facts",
       c do
    a = connect(c.port)
    on_exit(fn -> :gen_tcp.close(a) end)
    target_path = "/workers/box/W-1/R-1/attempt-1"
    send_message(a, %{"op" => "boot", "to" => target_path})
    boot = next(a, &(&1["op"] in ["boot", "boot_result", "boot_error"]))
    assert boot["initial_to"] == target_path

    for index <- 1..51 do
      assert {:result, _} =
               request(a, :worker_submit, %{
                 "execution" => target(),
                 "guidance" => guidance("batch-#{index}")
               })
    end

    assert {:result, %{"interactions" => first, "cursor" => cursor, "more" => true}} =
             request(a, :worker_history, %{"execution" => target()})

    assert Enum.map(first, & &1["client_key"]) == Enum.map(1..50, &"batch-#{&1}")

    assert {:result,
            %{
              "interactions" => [%{"client_key" => "batch-51"}],
              "cursor" => final,
              "more" => false
            }} =
             request(a, :worker_history, %{"execution" => target(), "cursor" => cursor})

    assert {:result, _} =
             request(a, :worker_submit, %{
               "execution" => target(),
               "guidance" => guidance("batch-52")
             })

    assert {:result, %{"interactions" => [%{"client_key" => "batch-52"}]}} =
             request(a, :worker_history, %{"execution" => target(), "cursor" => final})
  end
end
