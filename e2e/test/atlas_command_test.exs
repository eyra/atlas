defmodule AtlasE2E.AtlasCommandTest do
  # What `bin/atlas` refuses or chooses before it starts anything: no rela, no core and no
  # prod data is touched here. prod is the default; automation passes --env test or a
  # private ATLAS_ENV_FILE, and a mismatch between the two is refused.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp atlas(args, env \\ []) do
    System.cmd(Path.join(@root, "bin/atlas"), args,
      env: [{"ATLAS_ENV_FILE", nil}, {"ATLAS_NO_UPDATE", "1"} | env],
      stderr_to_stdout: true
    )
  end

  defp private_file(env) do
    dir = Path.join(System.tmp_dir!(), "atlas-command-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "#{env}.json")
    settings = @root |> Path.join("env/test.json") |> File.read!() |> JSON.decode!()
    File.write!(file, JSON.encode!(%{settings | "env" => env}))
    on_exit(fn -> File.rm_rf!(dir) end)
    file
  end

  test "prod is the default; --env test chooses test" do
    assert {"prod " <> file, 0} = atlas(["env"])
    assert String.trim(file) == Path.join(@root, "env/prod.json")
    assert {"test " <> file, 0} = atlas(["env", "--env", "test"])
    assert String.trim(file) == Path.join(@root, "env/test.json")
  end

  test "a private file is its own environment, and must agree with --env" do
    test_file = private_file("test")
    assert {"test " <> _, 0} = atlas(["env"], [{"ATLAS_ENV_FILE", test_file}])

    assert {out, 1} = atlas(["env", "--env", "prod"], [{"ATLAS_ENV_FILE", test_file}])
    assert out =~ "is for test, not prod"

    prod_file = private_file("prod")
    assert {out, 1} = atlas(["tui", "--env", "test"], [{"ATLAS_ENV_FILE", prod_file}])
    assert out =~ "is for prod, not test"
  end

  test "an unknown or empty environment is refused" do
    assert {out, 1} = atlas(["env", "--env", "staging"])
    assert out =~ "no environment 'staging'"
    assert {out, 2} = atlas(["env", "--env"])
    assert out =~ "--env needs test or prod"
    assert {_, 2} = atlas(["env", "--env="])
  end

  test "the end-to-end test refuses prod" do
    assert {out, 1} = atlas(["e2e", "--env", "prod"])
    assert out =~ "never on prod"
    assert {out, 1} = atlas(["e2e", "uc-atlas-01", "--env=prod"])
    assert out =~ "never on prod"
  end

  test "test and prod share no port and no data, and neither is the live store" do
    [test, prod] =
      for env <- ["test", "prod"],
          do: @root |> Path.join("env/#{env}.json") |> File.read!() |> JSON.decode!()

    assert {test["env"], prod["env"]} == {"test", "prod"}
    ports = fn s -> [s["rela"]["port"], s["control"]["port"]] end
    assert MapSet.disjoint?(MapSet.new(ports.(test)), MapSet.new(ports.(prod)))
    refute 7612 in (ports.(test) ++ ports.(prod))

    for key <- [["rela", "data"], ["rela", "bin"], ["state", "data"]] do
      refute get_in(test, key) == get_in(prod, key)
      assert get_in(prod, key) =~ "/atlas/prod/"
    end
  end
end
