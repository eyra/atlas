defmodule AtlasE2E.RuntimePlaygroundTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @tag timeout: 90_000
  test "a terminal viewer leaves the real private Runtime worker lifecycle independent" do
    {output, code} =
      System.cmd("python3", [Path.join(@root, "tools/runtime-playground/test_playground.py")],
        cd: @root,
        env: [
          {"ATLAS_CONFIG_PYTHON",
           System.get_env("ATLAS_CONFIG_PYTHON") || System.find_executable("python3")}
        ],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "PASS: attach/detach/reconnect identity"
  end
end
