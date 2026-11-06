Code.require_file(Path.expand("../../clients/agent/lib/atlas_agent/runtime_session.ex", __DIR__))

defmodule RuntimePlayground.Client do
  alias AtlasAgent.RuntimeSession, as: Session

  def run(mode, dir, worker, words) do
    target = %{"environment" => "private", "machine" => "private-playground", "worker" => worker}
    {:ok, socket} = connect(dir, 5)

    session =
      if mode == "attach" and match?(["--" <> _ | _], words) do
        case AtlasBFFContract.Wire.Runtime.AttachmentProtocol.options(
               :runtime_attachment_options,
               words
             ) do
          {:ok, options} ->
            AtlasAgent.RuntimeSession.attach(%{
              worker: target,
              turn: options["turn"],
              attempt: options["attempt"]
            })

          {:invalid, why} ->
            raise ArgumentError, why
        end
      else
        Session.new(target)
      end

    if mode == "probe" do
      {:ok, session} = issue(socket, words, session)
      probe(socket, session)
    else
      if session.execution do
        IO.puts(
          "\nPRIVATE Runtime · exact execution viewer\nActual Runtime/Bus/State/Flow; not deployed Control.\nExact execution #{session.execution["turn"]}/#{session.execution["attempt"]}; snapshot-only read-only.\nCommands: status | reconnect | detach. Guidance, harness output and replay unsupported.\nPrivate owner-only socket authority; no machine-read grant used.\nPrivate files: #{dir}\n"
        )
      else
        IO.puts(
          "\nPRIVATE Runtime · worker viewer\nActual Runtime + Bus + State + Flow; adapter selected at launch. No guidance support.\nWorker lifecycle is independent of this viewer.\nCommands: start | stop | status | output | list | help\n          reconnect | detach | quit (leaves worker running)\nPrivate files: #{dir}\n"
        )
      end

      IO.puts(
        "At most 8 outstanding requests; replies expire after 10 seconds (outcome unknown)."
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
          {:ok, :event, _, next} ->
            probe(socket, next)

          {:ok, :error, frame, _} ->
            IO.puts(JSON.encode!(frame))
            System.halt(1)

          {:ok, _, frame, _} ->
            IO.puts(JSON.encode!(frame))

          {:invalid, why, _} ->
            raise "invalid control response: #{why}"
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
           # packet_size alone does not grow the line driver's buffer: a long
           # JSON line otherwise arrives as multiple independently decoded chunks.
           [:binary, packet: :line, packet_size: 262_144, buffer: 262_144, active: false],
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
    output? = words == ["output"]
    words = if output?, do: ["status"], else: words

    case Session.request(session, words, now()) do
      {:ok, frame, next} ->
        next = if output?, do: put_in(next, [:pending, frame["id"], :output], true), else: next

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
      {:command, [command]} when command in ["detach", "quit"] ->
        issue(socket, ["detach"], session)
        :gen_tcp.close(socket)
        IO.puts("Detached. Worker lifecycle unchanged; any outstanding outcomes remain unknown.")

      {:command, ["reconnect"]} ->
        reconnect(socket, dir, session)

      {:command, []} ->
        loop(socket, dir, session)

      {:command, ["list"]} ->
        IO.puts(JSON.encode!(session.target))
        loop(socket, dir, session)

      {:command, ["help"]} ->
        IO.puts(
          "start | stop | status | output | list | reconnect | detach | quit; quit only detaches"
        )

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

          {:ok, _, %{"op" => "execution_closed"} = frame, _next} ->
            IO.puts(
              "Subscription closed: " <> frame["error"]["code"] <> "; no successor selected."
            )

            :gen_tcp.close(socket)

          {:ok, _, %{"turn" => turn}, next} ->
            IO.puts(
              "execution=#{turn["execution"]["turn"]}/#{turn["execution"]["attempt"]} state=#{turn["state"]} activity=#{turn["activity"]} lease=#{turn["lease_until"]}"
            )

            loop(socket, dir, next)

          {:ok, _, frame, next} ->
            if get_in(session.pending, [frame["id"], :output]),
              do: output(dir, frame["status"]),
              else: show(frame["status"])

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
        {:ok, fresh} = issue(next, ["attach"], AtlasAgent.RuntimeSession.reconnect(session))
        loop(next, dir, fresh)

      {:error, why} ->
        IO.puts("Disconnected: #{why}. Viewer did not issue stop; worker state is unknown.")
    end
  end

  def shutdown(dir) do
    alias AtlasBFFContract.Wire.Runtime.MachineProtocol, as: Wire
    {:ok, socket} = connect(dir, 1)
    target = %{environment: "private", machine: "private-playground"}
    id = Integer.to_string(System.unique_integer([:positive]))
    bytes = Wire.encode_request(:runtime_machine_stop, id: id, target: target)
    :ok = :gen_tcp.send(socket, bytes <> "\n")

    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, response} ->
        case Wire.decode_reply_json(:runtime_machine_stop, response) do
          {:ok, :result,
           %{
             "id" => ^id,
             "target" => %{"environment" => "private", "machine" => "private-playground"}
           } = frame} ->
            IO.puts(JSON.encode!(frame))

          {:ok, :error, frame} ->
            IO.puts(:stderr, JSON.encode!(frame))
            System.halt(1)

          other ->
            raise "shutdown not confirmed: #{inspect(other)}"
        end

      other ->
        raise "shutdown outcome unknown: #{inspect(other)}"
    end

    :gen_tcp.close(socket)
  end

  defp output(dir, status) do
    # Output remains a local artifact boundary, not a new control-wire operation.
    latest =
      Enum.max_by(
        status["turns"],
        fn turn ->
          turn["execution"]["turn"] |> String.split("-") |> List.last() |> String.to_integer()
        end,
        fn -> nil end
      )

    if latest do
      key = latest["execution"]["turn"]
      if Path.basename(key) != key, do: raise("invalid turn artifact path")
      path = Path.join([dir, "turns", key, "answer.txt"])

      case File.read(path) do
        {:ok, answer} -> IO.puts(answer)
        {:error, :enoent} -> IO.puts("No final answer recorded for #{key}")
        {:error, why} -> IO.puts("Output unavailable: #{inspect(why)}")
      end
    else
      IO.puts("No turn has run")
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
  ["shutdown", dir] ->
    RuntimePlayground.Client.shutdown(dir)

  [mode, dir, worker | words] when mode in ["attach", "probe"] ->
    RuntimePlayground.Client.run(mode, dir, worker, words)
end
