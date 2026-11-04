defmodule AtlasRuntime.ClaudeTest do
  # The `claude` port with a fake Claude Code: a script that prints stream-json lines. No
  # real Claude Code runs in any test.
  use ExUnit.Case, async: true

  alias AtlasRuntime.Agent.Claude

  @moduletag :tmp_dir

  defp fake(dir, body) do
    path = Path.join(dir, "fake-claude")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # A stand-in for the build's `atlas`: it says how it was called.
  defp atlas_bin(dir) do
    bin = Path.join(dir, "build-bin")
    File.mkdir_p!(bin)
    path = Path.join(bin, "atlas")
    File.write!(path, "#!/bin/sh\necho \"build atlas: $* (file=$ATLAS_ENV_FILE)\"\n")
    File.chmod!(path, 0o755)
    bin
  end

  defp opts(dir, command) do
    [
      agent: %{"command" => command},
      turns_dir: Path.join(dir, "turns"),
      env_file: Path.join(dir, "instance.json"),
      atlas_bin: atlas_bin(dir)
    ]
  end

  @turn %{key: "TU-1", item: "AS-1", agent: "trial"}

  defp messages(pid, acc \\ []) do
    receive do
      {:agent, ^pid, message} -> messages(pid, [message | acc])
    after
      2_000 -> Enum.reverse(acc)
    end
  end

  test "its stream is activity; exiting 0 ends the turn with its result; the stream is kept",
       %{tmp_dir: dir} do
    command =
      fake(dir, ~S"""
      printf '%s\n' '{"type":"system","subtype":"init"}'
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"atlas get AS-1"}}]}}'
      printf '%s\n' '{"type":"result","subtype":"success","result":"Handed it back.\nMore.","total_cost_usd":0.01}'
      """)

    {:ok, pid} = Claude.start(@turn, opts(dir, command))

    assert [
             {:activity, "system"},
             {:activity, "Bash: atlas get AS-1"},
             {:activity, "result: Handed it back."},
             {:ended, "Handed it back."}
           ] = messages(pid)

    stream = File.read!(Path.join([dir, "turns", "TU-1", "stream.jsonl"]))
    assert stream =~ ~s("total_cost_usd":0.01)
  end

  test "any other exit is a crash; stop kills the process", %{tmp_dir: dir} do
    {:ok, pid} = Claude.start(@turn, opts(dir, fake(dir, "exit 3\n")))
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:exit, 3}}, 2_000

    {:ok, pid} = Claude.start(%{@turn | key: "TU-2"}, opts(dir, fake(dir, "sleep 30\n")))
    %{os_pid: os_pid} = :sys.get_state(pid)
    :ok = Claude.stop(pid)
    Process.sleep(300)
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    assert status != 0
  end

  test "no command in the settings: nothing starts", %{tmp_dir: dir} do
    assert {:error, {:no_command, nil}} =
             Claude.start(@turn, Keyword.put(opts(dir, nil), :agent, %{}))
  end

  test "the turn's atlas is its instance's alone; its environment carries nothing else",
       %{tmp_dir: dir} do
    folder = Path.join(dir, "turn")
    o = opts(dir, "unused")
    :ok = Claude.wrapper(folder, o)
    env = Claude.environment(@turn, o, folder)

    assert env["PATH"] == Path.join(folder, "bin") <> ":" <> Path.join(folder, "sys")
    # Its sys folder holds what Claude Code needs for itself (macOS: security) and no more.
    assert File.ls!(Path.join(folder, "sys")) -- ["security"] == []
    assert env["ATLAS_AS"] == "trial" and env["ATLAS_ENV_FILE"] == o[:env_file]
    refute Map.has_key?(env, "GITHUB_TOKEN") or Map.has_key?(env, "MIX_ENV")

    run = fn command, extra ->
      System.cmd("/bin/sh", ["-c", command],
        env: Enum.to_list(Map.merge(env, extra)),
        stderr_to_stdout: true
      )
    end

    for command <- [
          "atlas get SC-Atlas-01 --env prod",
          "atlas list widget --env test",
          "atlas set IS-Atlas-01 title=x --env=prod",
          "atlas put widget --title x",
          "atlas help"
        ] do
      {out, status} = run.(command, %{})
      assert status == 2 and out =~ "atlas (turn): refused", "#{command}: #{out}"
    end

    {out, 2} = run.("atlas get X", %{"ATLAS_ENV_FILE" => "/elsewhere.json"})
    assert out =~ "ATLAS_ENV_FILE is not this turn's instance"

    {out, 0} = run.("atlas get X", %{})
    assert out =~ "build atlas: get X (file=#{o[:env_file]})"

    # Nothing but atlas is on its PATH.
    {out, status} = run.("atlas get X; ls ~", %{})
    assert out =~ "build atlas: get X" and out =~ ~r/ls: (command )?not found/ and status != 0
  end

  test "its command: confined, headless, with the agent's model and budget" do
    {exe, args} =
      Claude.command(@turn, %{"command" => "claude", "model" => "sonnet", "budget_usd" => 0.5})

    assert exe == "claude"

    for flag <- ~w(-p --restricted --strict-mcp-config --no-session-persistence --verbose),
        do: assert(flag in args)

    assert ["--tools", "Bash" | _] = Enum.drop_while(args, &(&1 != "--tools"))

    assert ["--permission-mode", "dontAsk" | _] =
             Enum.drop_while(args, &(&1 != "--permission-mode"))

    assert ["--allowedTools", "Bash(atlas get:*)", "Bash(atlas list:*)", "Bash(atlas set:*)" | _] =
             Enum.drop_while(args, &(&1 != "--allowedTools"))

    assert ["--max-budget-usd", "0.5" | _] = Enum.drop_while(args, &(&1 != "--max-budget-usd"))
  end
end
