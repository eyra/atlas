defmodule AtlasRuntime.NativeClaudeTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Agent.Native
  @moduletag :tmp_dir
  @init %{
    "type" => "system",
    "subtype" => "init",
    "session_id" => "claude-session",
    "model" => "claude-sonnet-4-6"
  }
  @result %{
    "type" => "result",
    "subtype" => "success",
    "is_error" => false,
    "result" => "Read the sample."
  }

  defp launch(dir, events) do
    command = Path.join(dir, "native-fixture")

    File.write!(
      command,
      "#!/bin/sh\ncat <<'EVENTS'\n" <>
        Enum.map_join(events, "\n", &JSON.encode!/1) <> "\nEVENTS\n"
    )

    File.chmod!(command, 0o700)

    Native.start(%{key: "claude-turn"},
      turns_dir: Path.join(dir, "turns"),
      agent: %{
        "backend" => "claude",
        "command" => command,
        "workspace" => dir,
        "goal" => "Read the sample"
      }
    )
  end

  test "Claude completion requires native identity and exposes no private assistant parts", %{
    tmp_dir: dir
  } do
    assistant = %{
      "type" => "assistant",
      "message" => %{
        "model" => "claude-sonnet-4-6",
        "content" => [
          %{"type" => "thinking", "thinking" => "private reasoning"},
          %{"type" => "tool_use", "name" => "Read", "input" => %{"file_path" => "private path"}}
        ]
      }
    }

    {:ok, pid} = launch(dir, [@init, assistant, @result])
    ref = Process.monitor(pid)
    assert_receive {:agent, ^pid, {:session, "claude-session"}}, 5_000
    assert_receive {:agent, ^pid, {:identity, "claude", "claude-sonnet-4-6"}}
    assert_receive {:agent, ^pid, {:ended, "Read the sample."}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert File.read!(Path.join(dir, "turns/claude-turn/answer.txt")) == "Read the sample."
    public = drain(pid) |> inspect()
    refute public =~ "private reasoning"
    refute public =~ "private path"
    assert public =~ "tool_name"
    assert File.read!(Path.join(dir, "turns/claude-turn/stream.jsonl")) =~ "private reasoning"
  end

  test "zero exit cannot mask errors, missing identity or another vendor's terminal events", %{
    tmp_dir: dir
  } do
    cases = [
      [@init, Map.put(@result, "is_error", true)],
      [@result],
      [Map.delete(@init, "model"), @result],
      [@init, %{"type" => "error"}, @result],
      [
        %{"type" => "thread.started", "thread_id" => "codex-session"},
        %{"type" => "turn.completed"}
      ]
    ]

    for {events, index} <- Enum.with_index(cases) do
      folder = Path.join(dir, Integer.to_string(index))
      File.mkdir_p!(folder)
      {:ok, pid} = launch(folder, events)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
      refute_received {:agent, ^pid, {:ended, _}}
    end
  end

  test "unsupported permissions, provisioning, resume and unknown vendors never launch", %{
    tmp_dir: dir
  } do
    for settings <- [
          %{"sandbox" => "workspace-write"},
          %{"sandbox" => nil, "permissions" => %{"root" => dir}},
          %{"repository" => %{"url" => "https://github.com/eyra/atlas.git"}},
          %{"session_id" => "existing-session"},
          %{"backend" => "unknown"}
        ] do
      base = %{
        "backend" => "claude",
        "command" => System.find_executable("sh"),
        "workspace" => dir,
        "goal" => "Never execute"
      }

      assert {:error, _} =
               Native.start(%{key: "refused"},
                 turns_dir: Path.join(dir, "turns"),
                 agent: Map.merge(base, settings)
               )

      refute File.exists?(Path.join(dir, "turns"))
    end
  end

  defp drain(pid) do
    receive do
      {:agent, ^pid, event} -> [event | drain(pid)]
    after
      0 -> []
    end
  end
end
