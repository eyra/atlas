defmodule AtlasE2E.RuntimePlaygroundTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @tag timeout: 60_000
  test "private stop selection and client session boundaries refuse stale or foreign data" do
    {output, code} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: Path.join(@root, "beam"),
        env: [{"MIX_ENV", "test"}, {"ELIXIR_ERL_OPTIONS", "+S 1:1"}],
        stderr_to_stdout: true
      )

    assert code == 0, output

    for script <- ~w(test_stop.py test_client_boundary.py) do
      {output, code} =
        System.cmd("python3", [Path.join(@root, "tools/runtime-playground/#{script}")],
          cd: @root,
          stderr_to_stdout: true
        )

      assert code == 0, output
    end

    paths =
      Path.wildcard(Path.join(@root, "beam/_build/test/lib/*/ebin"))
      |> Enum.flat_map(&["-pa", &1])

    {output, code} =
      System.cmd(
        "elixir",
        paths ++ [Path.join(@root, "tools/runtime-playground/client_test.exs")],
        cd: @root,
        env: [{"ELIXIR_ERL_OPTIONS", "+S 1:1"}],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "3 tests, 0 failures"
  end

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
