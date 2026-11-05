defmodule RuntimePlayground.Server do
  use GenServer
  alias AtlasBFFContract.Runtime.Protocol, as: Wire
  alias AtlasRuntime.Talk

  @target %{"environment" => "private", "machine" => "runtime-playground", "worker" => "breaker"}

  def start(dir, binary) do
    {:ok, _} = GenServer.start_link(__MODULE__, {dir, binary}, name: __MODULE__)
    Process.sleep(:infinity)
  end

  def init({dir, binary}) do
    Application.put_env(:atlas_bus, :environment, "private")
    :ok = AtlasBus.attach("playground")
    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    rela =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        args: [
          "-project",
          dir <> "/rela",
          "-bind",
          "127.0.0.1",
          "-port",
          to_string(port),
          "-quiet"
        ]
      ])

    {:os_pid, pid} = Port.info(rela, :os_pid)
    File.write!(dir <> "/rela.pid", to_string(pid))
    config = {AtlasState.Rela.Http, "http://127.0.0.1:#{port}/api/v1"}
    wait_store(config, 100)
    root = Path.expand("../..", __DIR__)

    {:ok, _} =
      Supervisor.start_child(
        AtlasState.Supervisor,
        {AtlasState.Server,
         rela: config, data_dir: dir <> "/state", description_extra: root <> "/rela/atlas.json"}
      )

    File.mkdir_p!(dir <> "/stub")
    File.write!(dir <> "/stub/breaker", "active")
    put("agent", "coordinator", %{"name" => "Coordinator"})
    put("agent", "breaker", %{"name" => "Private stub"})

    put("scene", "SC-Atlas-1", %{
      "title" => "PRIVATE Runtime playground",
      "status" => "ready_to_pick_up"
    })

    {:ok, flow} = Supervisor.start_child(AtlasFlow.Root, {AtlasFlow.Engine, every: 1000})
    AtlasFlow.Engine.round(flow)
    put("assignment", "AS-SC-Atlas-1", %{}, %{"assigned_to" => ["breaker"]}, "change")
    path = dir <> "/runtime.sock"

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, path},
        packet: :line,
        packet_size: 262_144,
        active: false
      ])

    File.chmod!(path, 0o600)
    spawn_link(fn -> accept(listener) end)
    state = %{dir: dir, rela: rela, engine: nil, subscribers: MapSet.new(), sequence: 0}
    status(state)

    File.write!(
      dir <> "/ready",
      "PRIVATE STUB; contract c341938; worker remains stopped until explicit start\n"
    )

    Process.send_after(self(), :tick, 1000)
    {:ok, state}
  end

  defp wait_store(_, 0), do: raise("private rela unavailable")

  defp wait_store(config, n) do
    case AtlasState.Rela.description(config) do
      {:ok, _} ->
        :ok

      _ ->
        Process.sleep(50)
        wait_store(config, n - 1)
    end
  end

  defp put(kind, key, values, links \\ %{}, op \\ "create") do
    case Talk.put(kind, %{
           "op" => op,
           "key" => key,
           "values" => values,
           "links" => links,
           "by" => "playground",
           "cause" => "private synthetic playground"
         }) do
      {:stored, _} -> :ok
      other -> raise "private fact refused: #{inspect(other)}"
    end
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)

    pid =
      spawn(fn ->
        receive do
          {:socket, s} -> connection(s)
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
        reply = GenServer.call(__MODULE__, {:request, bytes, self()}, 15_000)
        :gen_tcp.send(socket, reply <> "\n")
        connection(socket)

      {:snapshot, bytes} ->
        :gen_tcp.send(socket, bytes <> "\n")
        connection(socket)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _} ->
        :gen_tcp.close(socket)
    end
  end

  def handle_call({:request, bytes, viewer}, _from, state) do
    case Wire.decode_request_json(bytes) do
      {:ok, name, request} ->
        if request["target"] == @target do
          {state, error} = control(name, request, viewer, state)

          reply =
            if error do
              Wire.encode_reply(name, :error, %{
                id: request["id"],
                target: @target,
                error: %{code: "unsupported", message: error, retryable: false}
              })
            else
              Wire.encode_reply(name, :result, %{
                id: request["id"],
                target: @target,
                status: status(state)
              })
            end

          {:reply, reply, state}
        else
          {:reply,
           Wire.encode_reply(name, :error, %{
             id: request["id"],
             error: %{
               code: "wrong_target",
               message: "private worker identity mismatch",
               retryable: false
             }
           }), state}
        end

      {:invalid, why} ->
        {:reply,
         Wire.encode_reply(:runtime_status, :error, %{
           id: "invalid",
           error: %{code: "invalid_message", message: why, retryable: false}
         }), state}
    end
  end

  defp control(:runtime_start, _, _, state) do
    opts = [
      machine: "runtime-playground",
      agents: %{"breaker" => %{"port" => "stub"}},
      silence: 8_000,
      max: 120_000,
      lease: 1_000,
      every: 1_000,
      stub_dir: state.dir <> "/stub",
      turns_dir: state.dir <> "/turns",
      crash_pause: 1_000,
      leave_grace: 1_000
    ]

    pid =
      case engine_pid() do
        nil ->
          {:ok, pid} = Supervisor.start_child(AtlasRuntime.Root, {AtlasRuntime.Engine, opts})
          pid

        pid ->
          pid
      end

    {%{state | engine: pid}, nil}
  end

  defp control(:runtime_stop, _, _, state) do
    if engine_pid() do
      Supervisor.terminate_child(AtlasRuntime.Root, AtlasRuntime.Engine)
      Supervisor.delete_child(AtlasRuntime.Root, AtlasRuntime.Engine)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasRuntime.Supervisor),
          do: AtlasRuntime.Turn.finish(pid, "explicit private operator stop")
    end

    {%{state | engine: nil}, nil}
  end

  defp control(:runtime_attach, _, viewer, state) do
    Process.monitor(viewer)
    {%{state | subscribers: MapSet.put(state.subscribers, viewer)}, nil}
  end

  defp control(:runtime_detach, _, viewer, state),
    do: {%{state | subscribers: MapSet.delete(state.subscribers, viewer)}, nil}

  defp control(:runtime_status, _, _, state), do: {state, nil}

  defp control(_, %{"op" => "stub_mode", "mode" => mode}, _, state) do
    File.write!(state.dir <> "/stub/breaker", mode)
    {state, nil}
  end

  defp control(_, _, _, state),
    do: {state, "operation is not implemented by this private prototype"}

  defp fact(kind, key) do
    %{"fact" => fact} = Talk.read(kind, %{"key" => key})
    fact
  end

  defp engine_pid do
    Enum.find_value(Supervisor.which_children(AtlasRuntime.Root), fn
      {AtlasRuntime.Engine, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp status(state) do
    assignment = fact("assignment", "AS-SC-Atlas-1")
    worker = fact("agent", "breaker")
    %{"facts" => turns} = Talk.read("turn", %{})

    turns =
      turns
      |> Enum.filter(
        &(&1["values"]["machine"] == "runtime-playground" and
            &1["links"]["turn_by"] == ["breaker"])
      )
      |> Enum.sort_by(&(&1["values"]["ended_at"] || &1["values"]["lease_until"] || ""))
      |> Enum.map(fn t ->
        v = t["values"]
        execution = %{worker: @target, turn: t["key"], attempt: v["attempt"]}

        %{
          execution: execution,
          item: List.first(t["links"]["turn_on"] || []),
          state: v["state"],
          activity: v["activity"],
          lease_until: v["lease_until"],
          outcome: v["outcome"],
          reason: v["why"]
        }
      end)

    Wire.model(:runtime_status, %{
      target: @target,
      engine_running: engine_pid() != nil,
      capabilities: %{controls: %{status: true, start: true, stop: true, stub_mode: true}},
      item: "SC-Atlas-1",
      owner: Enum.join(assignment["links"]["assigned_to"] || [], ", "),
      expected: assignment["values"]["expected"],
      handover: assignment["values"]["handover"],
      mode: File.read!(state.dir <> "/stub/breaker") |> String.trim(),
      cannot_run: worker["values"]["cannot_run"],
      turns: turns
    })
  end

  def handle_info(:tick, state) do
    sequence = state.sequence + 1
    snapshot = status(state)

    bytes =
      Wire.encode_event(:runtime_status_event, %{
        sequence: sequence,
        target: @target,
        status: snapshot
      })

    File.write!(state.dir <> "/events.jsonl", bytes <> "\n", [:append])
    for pid <- state.subscribers, do: send(pid, {:snapshot, bytes})
    Process.send_after(self(), :tick, 1000)
    {:noreply, %{state | sequence: sequence}}
  end

  def handle_info({:DOWN, _, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}

  def handle_info({_, {:data, _}}, state), do: {:noreply, state}
  def handle_info({_, {:exit_status, code}}, _), do: raise("private rela exited #{code}")
  def handle_info({:atlas_bus, _, _}, state), do: {:noreply, state}
end

defmodule RuntimePlayground.Client do
  alias AtlasBFFContract.Runtime.Protocol, as: Wire

  defmodule Session do
    @moduledoc false
    alias AtlasBFFContract.Runtime.Protocol, as: Wire
    @limit 8
    @timeout 10_000
    def limit, do: @limit
    def timeout, do: @timeout
    def new(target), do: %{target: target, pending: %{}}

    def request(session, words, now) do
      if map_size(session.pending) >= @limit do
        {:error, :backpressure, session}
      else
        id = Integer.to_string(System.unique_integer([:positive]))

        case Wire.cli(words, %{id: id, target: session.target}) do
          {:ok, name, frame} ->
            entry = %{name: name, expires: now + @timeout}
            {:ok, frame, put_in(session, [:pending, id], entry)}

          {:invalid, why} ->
            {:error, why, session}
        end
      end
    end

    def expire(session, now) do
      {expired, remaining} =
        Enum.split_with(session.pending, fn {_, entry} -> entry.expires <= now end)

      {%{session | pending: Map.new(remaining)}, Enum.map(expired, &elem(&1, 0))}
    end

    def wait(session, now) do
      Enum.reduce(session.pending, 1000, fn {_, entry}, wait ->
        min(wait, max(entry.expires - now, 0))
      end)
    end

    def accept(session, bytes, now) do
      case Wire.decode_event_json(bytes) do
        {:ok, _, frame} ->
          if bound?(frame, session.target),
            do: {:ok, :event, frame, session},
            else: {:invalid, "event target mismatch", session}

        _ ->
          accept_reply(session, bytes, now)
      end
    end

    defp accept_reply(session, bytes, now) do
      with {:ok, %{"id" => id}} <- JSON.decode(bytes),
           %{name: name, expires: expires} when expires > now <- session.pending[id],
           {:ok, kind, frame} <- Wire.decode_reply_json(name, bytes) do
        if bound?(frame, session.target) do
          {:ok, kind, frame, %{session | pending: Map.delete(session.pending, id)}}
        else
          {:invalid, "reply target mismatch", session}
        end
      else
        _ -> {:invalid, "malformed, expired, duplicate or unknown reply", session}
      end
    end

    defp bound?(%{"op" => "error"} = frame, target),
      do: not Map.has_key?(frame, "target") or frame["target"] == target

    defp bound?(frame, target) do
      frame["target"] == target and frame["status"]["target"] == target and
        Enum.all?(frame["status"]["turns"], &(&1["execution"]["worker"] == target))
    end
  end

  def run(mode, dir, worker, words) do
    target = %{"environment" => "private", "machine" => "runtime-playground", "worker" => worker}
    {:ok, socket} = connect(dir, 5)
    session = Session.new(target)

    if mode == "probe" do
      {:ok, session} = issue(socket, words, session)
      probe(socket, session)
    else
      IO.puts(
        "\nRuntime Playground · UC46 / IS125 · PRIVATE STUB\nActual Runtime + Bus + State + Flow; no model or guidance support.\nWorker lifecycle is independent of this viewer.\nCommands: start | stop | status | mode active/idle/silent/crash-once/crash\n          reconnect | detach (leaves worker running)\nAt most 8 outstanding requests; replies expire after 10 seconds (outcome unknown).\nPrivate files: #{dir}\n"
      )

      parent = self()
      spawn_link(fn -> input(parent) end)
      {:ok, session} = issue(socket, ["attach"], session)
      loop(socket, dir, session)
    end
  end

  defp probe(socket, session) do
    wait = Session.wait(session, now())

    case :gen_tcp.recv(socket, 0, wait) do
      {:ok, bytes} ->
        case Session.accept(session, bytes, now()) do
          {:ok, :event, _, next} -> probe(socket, next)
          {:ok, _, frame, _} -> IO.puts(JSON.encode!(frame))
          {:invalid, why, _} -> raise "invalid control response: #{why}"
        end

      {:error, :timeout} ->
        {next, expired} = Session.expire(session, now())
        if expired != [], do: raise("request expired; outcome unknown"), else: probe(socket, next)

      {:error, why} ->
        raise "control connection failed: #{why}; outcome unknown"
    end
  end

  defp connect(_, 0), do: {:error, :reconnect_exhausted}

  defp connect(dir, n) do
    case :gen_tcp.connect(
           {:local, dir <> "/runtime.sock"},
           0,
           [:binary, packet: :line, packet_size: 262_144, active: false],
           1000
         ) do
      {:ok, socket} ->
        {:ok, socket}

      _ ->
        Process.sleep(300)
        connect(dir, n - 1)
    end
  end

  defp input(parent) do
    case IO.gets("runtime> ") do
      line when is_binary(line) ->
        send(parent, {:command, String.split(line)})
        input(parent)

      _ ->
        send(parent, {:command, ["detach"]})
    end
  end

  defp issue(socket, words, session) do
    case Session.request(session, words, now()) do
      {:ok, frame, next} ->
        case :gen_tcp.send(socket, JSON.encode!(frame) <> "\n") do
          :ok -> {:ok, next}
          {:error, why} -> {:error, why, session}
        end

      other ->
        other
    end
  end

  defp loop(socket, dir, session) do
    {session, expired} = Session.expire(session, now())
    for id <- expired, do: IO.puts("EXPIRED request #{id}; outcome unknown")
    :inet.setopts(socket, active: :once)

    receive do
      {:command, ["detach"]} ->
        issue(socket, ["detach"], session)
        :gen_tcp.close(socket)
        IO.puts("Detached. Worker lifecycle unchanged; any outstanding outcomes remain unknown.")

      {:command, ["reconnect"]} ->
        reconnect(socket, dir, session)

      {:command, []} ->
        loop(socket, dir, session)

      {:command, words} ->
        case issue(socket, words, session) do
          {:ok, next} ->
            loop(socket, dir, next)

          {:error, :backpressure, next} ->
            IO.puts("BACKPRESSURE: 8 requests outstanding; wait for replies or expiry")
            loop(socket, dir, next)

          {:error, why, next} ->
            IO.puts("Command not sent: #{inspect(why)}")
            loop(socket, dir, next)
        end

      {:tcp, ^socket, bytes} ->
        case Session.accept(session, bytes, now()) do
          {:ok, :error, frame, next} ->
            IO.puts("ERROR " <> inspect(frame["error"]))
            loop(socket, dir, next)

          {:ok, _, frame, next} ->
            show(frame["status"])
            loop(socket, dir, next)

          {:invalid, why, next} ->
            IO.puts("INVALID " <> why)
            loop(socket, dir, next)
        end

      {:tcp_closed, ^socket} ->
        reconnect(socket, dir, session)

      {:tcp_error, ^socket, _} ->
        reconnect(socket, dir, session)
    after
      Session.wait(session, now()) -> loop(socket, dir, session)
    end
  end

  defp reconnect(socket, dir, session) do
    :gen_tcp.close(socket)

    IO.puts(
      "Reconnecting (at most five attempts; no lifecycle command). #{map_size(session.pending)} outstanding outcomes unknown; controls are not replayed."
    )

    case connect(dir, 5) do
      {:ok, next} ->
        {:ok, fresh} = issue(next, ["attach"], Session.new(session.target))
        loop(next, dir, fresh)

      {:error, why} ->
        IO.puts("Disconnected: #{why}. Worker was not stopped.")
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp show(status) do
    IO.puts(
      "engine=#{status["engine_running"]} mode=#{status["mode"]} owner=#{status["owner"]} item=#{status["item"]} expected=#{status["expected"]} handover=#{status["handover"] || "none"} cannot_run=#{status["cannot_run"] || "none"}"
    )

    for turn <- Enum.take(status["turns"], -4) do
      IO.puts(
        "  #{turn["execution"]["turn"]} #{turn["state"]} activity=#{turn["activity"]} lease=#{turn["lease_until"]} outcome=#{turn["outcome"] || "none stored"} reason=#{turn["reason"]}"
      )
    end
  end
end

case System.argv() do
  ["server", dir, binary] ->
    RuntimePlayground.Server.start(dir, binary)

  [mode, dir, worker | words] when mode in ["attach", "probe"] ->
    RuntimePlayground.Client.run(mode, dir, worker, words)
end
