defmodule AtlasRuntime.CodexTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Agent.Codex
  @moduletag :tmp_dir
  @turn %{key: "TU-CODEX-1", item: "work", agent: "worker"}

  defp launch(dir, script, owner \\ nil, settings \\ %{}) do
    command = Path.join(dir, "fake-codex")
    File.write!(command, "#!/bin/sh\n" <> script)
    File.chmod!(command, 0o700)

    opts = [
      turns_dir: Path.join(dir, "turns"),
      agent:
        Map.merge(
          %{"command" => command, "workspace" => dir, "goal" => "Explain the sample"},
          settings
        )
    ]

    if owner, do: send(owner, {:launch, opts}), else: Codex.start(@turn, opts)
  end

  test "clean exit and completed event preserve the real final answer", %{tmp_dir: dir} do
    {:ok, pid} =
      launch(dir, ~S"""
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"The sample totals prices and applies tax."}}'
      printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1}}'
      """)

    ref = Process.monitor(pid)
    assert_receive {:agent, ^pid, {:ended, "The sample totals prices and applies tax."}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "normal completion terminates descendants with redirected output", %{tmp_dir: dir} do
    {:ok, pid} =
      launch(dir, ~S"""
      sleep 60 </dev/null >/dev/null 2>&1 &
      printf '{"type":"item.started","item":{"text":"child=%s"}}\n' "$!"
      printf '%s\n' '{"type":"turn.completed"}'
      """)

    assert_receive {:agent, ^pid, {:activity, "codex: child=" <> child}}, 5_000
    child = String.trim(child)
    on_exit(fn -> System.cmd("kill", ["-KILL", child], stderr_to_stdout: true) end)
    assert_receive {:agent, ^pid, {:ended, _}}, 5_000
    assert_dead(child)
  end

  test "zero exit without completion is not success", %{tmp_dir: dir} do
    {:ok, pid} = launch(dir, "exit 0\n")
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_failed, 0, 0}}, 5_000
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "a failure event or nonzero exit cannot be reported as completion", %{tmp_dir: dir} do
    for {suffix, script, code} <- [
          {"failed",
           ~S"""
           printf '%s\n' '{"type":"turn.failed","error":{"message":"Login expired"}}' '{"type":"turn.completed"}'
           """, 0},
          {"exit", "printf '%s\\n' '{\"type\":\"turn.completed\"}'\nexit 7\n", 7}
        ] do
      path = Path.join(dir, suffix)
      File.mkdir_p!(path)
      {:ok, pid} = launch(path, script)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_failed, 0, ^code}}, 5_000
      refute_received {:agent, ^pid, {:ended, _}}
    end
  end

  test "stop waits for the child process group to terminate", %{tmp_dir: dir} do
    {:ok, pid} =
      launch(dir, ~S"""
      sleep 60 &
      child=$!
      printf '{"type":"item.started","item":{"text":"child=%s"}}\n' "$child"
      wait
      """)

    assert_receive {:agent, ^pid, {:activity, "codex: child=" <> child}}, 5_000
    assert :ok = Codex.stop(pid)
    refute Process.alive?(pid)
    assert_dead(String.trim(child))
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "losing the turn owner stops the worker too", %{tmp_dir: dir} do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:launch, opts} ->
            {:ok, adapter} = Codex.start(@turn, opts)
            send(parent, {:adapter, adapter})

            receive do
              {:agent, ^adapter, {:activity, activity}} -> send(parent, {:activity, activity})
            end

            receive do
              :done -> :ok
            end
        end
      end)

    launch(
      dir,
      ~S"""
      printf '{"type":"item.started","item":{"text":"child=%s"}}\n' "$$"
      sleep 60
      """,
      owner
    )

    assert_receive {:adapter, adapter}, 5_000
    ref = Process.monitor(adapter)
    assert_receive {:activity, "codex: child=" <> child}, 5_000
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^adapter, :normal}, 8_000
    assert_dead(String.trim(child))
  end

  test "an unsupported sandbox is refused before launching a process", %{tmp_dir: dir} do
    opts = [
      turns_dir: Path.join(dir, "turns"),
      agent: %{
        "command" => System.find_executable("sh"),
        "workspace" => dir,
        "goal" => "Do not execute",
        "sandbox" => "danger-full-access"
      }
    ]

    assert {:error, _} = Codex.start(@turn, opts)
    refute File.exists?(Path.join(dir, "turns"))
  end

  test "resume refuses a different native session instead of completing a replacement", %{
    tmp_dir: dir
  } do
    {:ok, pid} =
      launch(
        dir,
        ~S"""
        printf '%s\n' '{"type":"thread.started","thread_id":"different-session"}'
        printf '%s\n' '{"type":"turn.completed"}'
        """,
        nil,
        %{"session_id" => "expected-session"}
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_failed, 1, nil}}, 5_000
    refute_received {:agent, ^pid, {:session, _}}
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "resume cannot report success without native session confirmation", %{tmp_dir: dir} do
    {:ok, pid} =
      launch(
        dir,
        ~S"""
        printf '%s\n' '{"type":"turn.completed"}'
        """,
        nil,
        %{"session_id" => "expected-session"}
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_failed, 1, nil}}, 5_000
    refute_received {:agent, ^pid, {:ended, _}}
  end

  defp assert_dead(pid) do
    {state, _} = System.cmd("ps", ["-p", pid, "-o", "stat="], stderr_to_stdout: true)
    assert String.trim(state) == "" or String.starts_with?(String.trim(state), "Z")
  end
end
