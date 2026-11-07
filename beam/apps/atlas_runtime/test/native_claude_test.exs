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
  @weekly __DIR__
          |> Path.join("fixtures/claude_weekly_quota.json")
          |> File.read!()
          |> JSON.decode!()

  defp launch(dir, events, settings \\ %{}) do
    command = Path.join(dir, "native-fixture")

    File.write!(
      command,
      "#!/bin/sh\ncat <<'EVENTS'\n" <>
        Enum.map_join(events, "\n", &JSON.encode!/1) <> "\nEVENTS\n"
    )

    File.chmod!(command, 0o700)

    Native.start(%{key: "claude-turn"},
      turns_dir: Path.join(dir, "turns"),
      agent:
        Map.merge(
          %{
            "backend" => "claude",
            "command" => command,
            "workspace" => dir,
            "goal" => "Read the sample"
          },
          settings
        )
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

  test "native identity overrides requested alias and ignores synthetic error identity", %{
    tmp_dir: dir
  } do
    init = Map.put(@init, "model", "claude-opus-5-5[1m]")

    synthetic = %{
      "type" => "assistant",
      "message" => %{"model" => "<synthetic>", "content" => []}
    }

    {:ok, pid} = launch(dir, [init, synthetic, @result], %{"model" => "opus[1m]"})
    ref = Process.monitor(pid)
    assert_receive {:agent, ^pid, {:identity, "claude", "claude-opus-5-5[1m]"}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    refute_received {:agent, ^pid, {:identity, _, _}}
  end

  test "observed weekly rejection emits exact quota once without retrying the turn", %{
    tmp_dir: dir
  } do
    init = Map.put(@init, "model", "claude-opus-5-5[1m]")

    synthetic = %{
      "type" => "assistant",
      "message" => %{
        "model" => "<synthetic>",
        "content" => [%{"type" => "text", "text" => "Weekly limit reached"}],
        "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
      }
    }

    {:ok, pid} =
      launch(dir, [init, @weekly, synthetic, @weekly, Map.put(@result, "is_error", true)])

    ref = Process.monitor(pid)
    evidence = @weekly["rate_limit_info"]
    assert_receive {:agent, ^pid, {:quota, ^evidence}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
    refute_received {:agent, ^pid, {:quota, _}}
    refute_received {:agent, ^pid, {:identity, "claude", "<synthetic>"}}
    refute_received {:agent, ^pid, {:ended, _}}
  end

  test "generic, auth, network and other rate limits are not weekly quota", %{tmp_dir: dir} do
    info = @weekly["rate_limit_info"]

    events = [
      %{"type" => "error", "message" => "weekly quota exceeded"},
      %{"type" => "error", "error" => %{"type" => "authentication_error"}},
      %{"type" => "error", "message" => "Network timeout"},
      %{"type" => "rate_limit_event", "rate_limit_info" => Map.put(info, "status", "allowed")},
      %{"type" => "rate_limit_event", "rate_limit_info" => Map.put(info, "isUsingOverage", true)},
      %{
        "type" => "rate_limit_event",
        "rate_limit_info" => Map.put(info, "overageStatus", "allowed")
      },
      %{
        "type" => "rate_limit_event",
        "rate_limit_info" => Map.put(info, "rateLimitType", "five_hour")
      },
      %{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "rejected"}},
      %{"type" => "rate_limit_event", "rate_limit_info" => nil}
    ]

    {:ok, pid} = launch(dir, [@init | events] ++ [Map.put(@result, "is_error", true)])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
    refute_received {:agent, ^pid, {:quota, _}}
  end

  test "weekly quota never parses localized reset text", %{tmp_dir: dir} do
    for {reset, index} <- Enum.with_index([nil, "November 7 at 6pm", "1794052800", -1, true]) do
      folder = Path.join(dir, Integer.to_string(index))
      File.mkdir_p!(folder)
      event = put_in(@weekly, ["rate_limit_info", "resetsAt"], reset)
      {:ok, pid} = launch(folder, [@init, event, Map.put(@result, "is_error", true)])
      ref = Process.monitor(pid)
      assert_receive {:agent, ^pid, {:quota, %{"resetsAt" => nil}}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, {:claude_failed, 0, 0}}, 5_000
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
          %{"backend" => "unknown"},
          %{"model" => ""},
          %{"model" => "--dangerously-skip-permissions"},
          %{"model" => "opus\n--tools Bash"},
          %{"model" => ["opus"]},
          %{"model" => String.duplicate("x", 201)}
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
