Code.require_file(Path.join(__DIR__, "attachment.exs"))

defmodule AtlasRuntime.Playground do
  use GenServer
  alias AtlasBFFContract.Runtime.Protocol, as: Wire
  alias AtlasBFFContract.Runtime.MachineProtocol, as: MachineWire
  alias AtlasBFFContract.Runtime.AttachmentProtocol, as: AttachmentWire
  alias AtlasRuntime.Talk

  @worker "breaker"
  @machine "private-playground"
  @target %{"environment" => "private", "machine" => @machine, "worker" => @worker}
  @machine_target Map.take(@target, ["environment", "machine"])

  def run(dir, port) do
    {:ok, _} = GenServer.start_link(__MODULE__, {dir, port}, name: __MODULE__)
    Process.sleep(:infinity)
  end

  def init({dir, port}) do
    settings = dir |> Path.join("worker.json") |> File.read!() |> JSON.decode!()
    Application.put_env(:atlas_runtime, :playground_agent, settings)
    Application.put_env(:atlas_bus, :environment, "private")
    :ok = AtlasBus.attach("private-playground-console")

    {:ok, _} =
      Supervisor.start_child(
        AtlasState.Supervisor,
        {AtlasState.Server,
         rela: {AtlasState.Rela.Http, "http://127.0.0.1:#{port}/api/v1"},
         data_dir: Path.join(dir, "state"),
         description_extra: Path.expand("../../rela/atlas.json", __DIR__)}
      )

    File.mkdir_p!(Path.join(dir, "stub"))
    File.write!(Path.join(dir, "stub/breaker"), "active")
    put!("agent", "coordinator", %{"name" => "Coordinator"})
    put!("agent", @worker, %{"name" => "Private #{settings["port"]} worker"})

    put!("scene", "SC-Atlas-1", %{
      "title" => "PRIVATE Runtime prototype",
      "status" => "ready_to_pick_up"
    })

    {:ok, flow} = Supervisor.start_child(AtlasFlow.Root, {AtlasFlow.Engine, every: 10_000})
    AtlasFlow.Engine.round(flow)
    put!("assignment", "AS-SC-Atlas-1", %{}, %{"assigned_to" => [@worker]}, "change")
    path = Path.join(dir, "runtime.sock")

    {:ok, listener} =
      :gen_tcp.listen(
        0,
        [
          :binary,
          ifaddr: {:local, path},
          packet: :line,
          packet_size: 262_144,
          buffer: 262_144,
          active: false
        ]
      )

    File.chmod!(path, 0o600)
    spawn_link(fn -> accept(listener) end)
    File.write!(Path.join(dir, "ready"), "PRIVATE Runtime; worker stopped until explicit start\n")
    Process.send_after(self(), :tick, 5_000)
    {:ok, %{dir: dir, subscribers: %{}, sequence: 0, shutting_down: false}}
  end

  defp put!(kind, key, values, links \\ %{}, op \\ "create") do
    case Talk.put(kind, %{
           "op" => op,
           "key" => key,
           "values" => values,
           "links" => links,
           "by" => "playground",
           "cause" => "private synthetic prototype"
         }) do
      {:stored, _} -> :ok
      other -> raise "Private seed failed: #{inspect(other)}"
    end
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)

    pid =
      spawn(fn ->
        receive do
          {:socket, socket} -> connection(socket)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, {:socket, socket})
    accept(listener)
  end

  defp connection(socket) do
    :inet.setopts(socket, active: :once)

    receive do
      {:tcp, ^socket, bytes} ->
        {reply, shutdown?} = GenServer.call(__MODULE__, {:request, bytes, self()}, 30_000)
        :gen_tcp.send(socket, reply <> "\n")

        if shutdown? do
          :gen_tcp.close(socket)
          send(__MODULE__, :shutdown)
        else
          connection(socket)
        end

      {:snapshot, bytes} ->
        case :gen_tcp.send(socket, bytes <> "\n") do
          :ok -> connection(socket)
          _ -> :gen_tcp.close(socket)
        end

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _} ->
        :gen_tcp.close(socket)
    end
  end

  def handle_call({:request, bytes, _viewer}, _from, %{shutting_down: true} = state) do
    request =
      case Wire.decode_request_json(bytes) do
        {:ok, _, request} -> request
        _ -> %{"id" => "invalid"}
      end

    reply =
      error_reply(Wire, :runtime_status, request, %{error: "Private Runtime is shutting down"})

    {:reply, {reply, false}, state}
  end

  def handle_call({:request, bytes, viewer}, _from, state) do
    case MachineWire.decode_request_json(bytes) do
      {:ok, :runtime_machine_stop, %{"target" => @machine_target} = request} ->
        case safe(fn -> stop() end) do
          %{error: _} = error ->
            {:reply, {error_reply(MachineWire, :runtime_machine_stop, request, error), false},
             state}

          _ ->
            snapshot = %{
              target: @machine_target,
              state: "stopped",
              basis: "private_controller",
              message: "Worker stopped; private instance shutting down",
              capabilities: %{
                local_status: false,
                local_start: false,
                local_stop: true,
                remote_status: false
              }
            }

            reply =
              MachineWire.encode_reply(:runtime_machine_stop, :result,
                id: request["id"],
                target: @machine_target,
                status: snapshot
              )

            File.rm(Path.join(state.dir, "ready"))
            {:reply, {reply, true}, %{state | shutting_down: true}}
        end

      _ ->
        worker_request(bytes, viewer, state)
    end
  end

  defp worker_request(bytes, viewer, state) do
    case AttachmentWire.decode_request_json(bytes) do
      {:ok, name, request} ->
        case safe(fn -> wire_status() end) do
          %{error: _} = error ->
            reply =
              AttachmentWire.encode_reply(name, :error,
                id: request["id"],
                target: request["target"],
                execution: request["execution"],
                error: %{code: "state_unavailable", message: inspect(error), retryable: false}
              )

            {:reply, {reply, false}, state}

          snapshot ->
            {kind, reply} = RuntimePlayground.Attachment.reply(name, request, snapshot, @target)

            state =
              case {kind, name} do
                {:ok, :execution_attach} -> subscribe(state, viewer, true, request["execution"])
                {:ok, :execution_detach} -> subscribe(state, viewer, false, nil)
                _ -> state
              end

            {:reply, {reply, false}, state}
        end

      _ ->
        control_request(bytes, viewer, state)
    end
  end

  defp control_request(bytes, viewer, state) do
    case Wire.decode_request_json(bytes) do
      {:ok, name, %{"target" => @target} = request} ->
        result =
          safe(fn ->
            case name do
              :runtime_start -> start(state.dir)
              :runtime_stop -> stop()
              name when name in [:runtime_status, :runtime_attach, :runtime_detach] -> :ok
              _ -> %{error: "Unsupported command in this private Runtime"}
            end
          end)

        snapshot =
          if is_map(result) and Map.has_key?(result, :error),
            do: result,
            else: safe(fn -> wire_status() end)

        case snapshot do
          %{error: _} = error ->
            {:reply, {error_reply(Wire, name, request, error), false}, state}

          _ ->
            state =
              case name do
                :runtime_attach -> subscribe(state, viewer, true, nil)
                :runtime_detach -> subscribe(state, viewer, false, nil)
                _ -> state
              end

            reply =
              Wire.encode_reply(name, :result,
                id: request["id"],
                target: @target,
                status: snapshot
              )

            {:reply, {reply, false}, state}
        end

      {:ok, name, request} ->
        {:reply,
         {error_reply(Wire, name, request, %{error: "Wrong private worker target"}), false},
         state}

      {:invalid, why} ->
        {:reply, {error_reply(Wire, :runtime_status, %{"id" => "invalid"}, %{error: why}), false},
         state}
    end
  end

  defp error_reply(wire, name, request, error) do
    wire.encode_reply(name, :error,
      id: request["id"],
      error: %{code: "not_confirmed", message: inspect(error), retryable: false}
    )
  end

  defp subscribe(state, viewer, attach?, execution) do
    if entry = state.subscribers[viewer], do: Process.demonitor(entry.monitor, [:flush])

    subscribers =
      if attach?,
        do:
          Map.put(state.subscribers, viewer, %{
            monitor: Process.monitor(viewer),
            execution: execution
          }),
        else: Map.delete(state.subscribers, viewer)

    %{state | subscribers: subscribers}
  end

  def handle_info(:tick, state) do
    state = %{state | sequence: state.sequence + 1}

    state =
      if map_size(state.subscribers) == 0 do
        state
      else
        case safe(fn -> wire_status() end) do
          %{error: _} ->
            state

          snapshot ->
            Enum.reduce(state.subscribers, state, fn {viewer, entry}, acc ->
              {bytes, keep?} =
                if entry.execution do
                  case RuntimePlayground.Attachment.select(snapshot, entry.execution, @target) do
                    {:ok, turn} ->
                      fields = RuntimePlayground.Attachment.fields(entry.execution, turn)

                      {AttachmentWire.encode_event(
                         :execution_snapshot,
                         Map.put(fields, :sequence, state.sequence)
                       ), true}

                    {:error, code} ->
                      fields = RuntimePlayground.Attachment.error(entry.execution, code)

                      {AttachmentWire.encode_event(
                         :execution_closed,
                         Map.put(fields, :sequence, state.sequence)
                       ), false}
                  end
                else
                  {Wire.encode_event(:runtime_status_event,
                     sequence: state.sequence,
                     target: @target,
                     status: snapshot
                   ), true}
                end

              send(viewer, {:snapshot, bytes})
              if keep?, do: acc, else: subscribe(acc, viewer, false, nil)
            end)
        end
      end

    Process.send_after(self(), :tick, 5_000)
    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, viewer, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, viewer)}}

  def handle_info(:shutdown, state) do
    File.rm(Path.join(state.dir, "ready"))
    System.stop(0)
    {:noreply, state}
  end

  def handle_info({:atlas_bus, _, _}, state), do: {:noreply, state}

  defp wire_status do
    case status() do
      %{error: _} = error ->
        error

      snapshot ->
        Wire.model(:runtime_status,
          target: @target,
          engine_running: snapshot.engine_running,
          capabilities: %{controls: %{status: true, start: true, stop: true, stub_mode: false}},
          item: "SC-Atlas-1",
          owner: @worker,
          mode: settings()["port"],
          turns: snapshot.turns
        )
    end
  end

  # Reads returning errors (including State's retry timeout) are data, not crashes.
  # Unexpected failures also produce an explicit reply; mutations are never replayed.
  defp safe(fun) do
    fun.()
  rescue
    error ->
      %{error: Exception.message(error), outcome: "not confirmed; inspect status before retrying"}
  catch
    :exit, reason ->
      %{error: inspect(reason), outcome: "not confirmed; inspect status before retrying"}
  end

  defp settings, do: Application.fetch_env!(:atlas_runtime, :playground_agent)

  defp engine do
    Enum.find_value(Supervisor.which_children(AtlasRuntime.Root), fn
      {AtlasRuntime.Engine, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp local_turns, do: DynamicSupervisor.which_children(AtlasRuntime.Supervisor)

  defp status do
    case Talk.read("turn", %{"linked" => %{}, "plain" => true}) do
      %{"facts" => facts} ->
        turns =
          Enum.filter(facts, fn t ->
            t["values"]["machine"] == @machine and t["links"]["turn_by"] == [@worker]
          end)

        running = Enum.filter(turns, &(&1["values"]["state"] == "running"))

        latest =
          Enum.max_by(
            turns,
            &(&1["values"]["ended_at"] || &1["values"]["lease_until"] || ""),
            fn -> nil end
          )

        %{
          worker: @worker,
          adapter: settings()["port"],
          goal: settings()["goal"],
          workspace: settings()["workspace"],
          turn_count: length(turns),
          engine_running: engine() != nil,
          local_turns: length(local_turns()),
          running_turns: Enum.map(running, &summary/1),
          latest_turn: if(latest, do: summary(latest), else: nil),
          turns:
            turns
            |> Enum.sort_by(& &1["key"])
            |> Enum.map(fn t ->
              %{
                execution: %{worker: @target, turn: t["key"], attempt: t["values"]["attempt"]},
                item: List.first(t["links"]["turn_on"] || []),
                state: t["values"]["state"],
                activity: t["values"]["activity"],
                lease_until: t["values"]["lease_until"],
                outcome: t["values"]["outcome"],
                reason: t["values"]["why"]
              }
            end)
        }

      error ->
        %{error: "State status unavailable", detail: error, engine_running: engine() != nil}
    end
  end

  defp summary(turn) do
    %{
      key: turn["key"],
      state: turn["values"]["state"],
      activity: turn["values"]["activity"],
      lease_until: turn["values"]["lease_until"],
      reason: turn["values"]["why"]
    }
  end

  defp start(dir) do
    case status() do
      %{error: _} = error ->
        error

      %{local_turns: n} = snapshot when n > 0 ->
        snapshot

      snapshot ->
        if settings()["port"] == "codex" and engine() do
          :ok = Supervisor.terminate_child(AtlasRuntime.Root, AtlasRuntime.Engine)
          :ok = Supervisor.delete_child(AtlasRuntime.Root, AtlasRuntime.Engine)
        end

        if engine() == nil do
          agent =
            if settings()["port"] == "codex",
              do: Map.put(settings(), "turn_limit", snapshot.turn_count + 1),
              else: settings()

          opts = [
            machine: @machine,
            agents: %{@worker => agent},
            silence: if(agent["port"] == "codex", do: 120_000, else: 8_000),
            max: if(agent["port"] == "codex", do: 300_000, else: 120_000),
            lease: 1_000,
            every: 1_000,
            stub_dir: Path.join(dir, "stub"),
            turns_dir: Path.join(dir, "turns"),
            crash_pause: 1_000,
            leave_grace: 1_000
          ]

          {:ok, _} = Supervisor.start_child(AtlasRuntime.Root, {AtlasRuntime.Engine, opts})
        end

        await({:started, snapshot.turn_count}, System.monotonic_time(:millisecond) + 10_000)
    end
  end

  defp stop do
    if engine() do
      :ok = Supervisor.terminate_child(AtlasRuntime.Root, AtlasRuntime.Engine)
      :ok = Supervisor.delete_child(AtlasRuntime.Root, AtlasRuntime.Engine)
    end

    for {_, pid, _, _} <- local_turns(),
        do: AtlasRuntime.Turn.finish(pid, "explicit private operator stop")

    await(:stopped, System.monotonic_time(:millisecond) + 10_000)
  end

  defp await(desired, deadline) do
    snapshot = status()

    cond do
      Map.has_key?(snapshot, :error) ->
        snapshot

      match?({:started, _}, desired) and snapshot.turn_count > elem(desired, 1) and
          (length(snapshot.running_turns) == 1 or snapshot.local_turns == 0) ->
        snapshot

      desired == :stopped and snapshot.local_turns == 0 and snapshot.running_turns == [] ->
        snapshot

      System.monotonic_time(:millisecond) >= deadline ->
        %{
          error: "Lifecycle transition not confirmed before deadline",
          observed: snapshot,
          outcome: "unknown; inspect status; command was not replayed"
        }

      true ->
        Process.sleep(100)
        await(desired, deadline)
    end
  end
end

[dir, port] = System.argv()
AtlasRuntime.Playground.run(dir, String.to_integer(port))
