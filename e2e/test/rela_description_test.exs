defmodule AtlasE2E.RelaDescriptionTest do
  # IS-Atlas-73: `atlas restart` restarts rela when rela runs an older description than
  # the build, its data kept, and refuses when the build's description would leave data
  # without one. On a private instance (free ports, data in a temporary folder), never on
  # env/test.json's or env/prod.json's.
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  @root Path.expand("../..", __DIR__)

  # An older description: this build's, and a kind it no longer has.
  @gone """
    e2e_gone:
      label: Gone
      plural: e2e_gones
      aliases: [gone]
      id_type: manual
      id_prefix: "G-"
      description: A kind this build no longer has.
      properties:
        title: { type: string, required: true }
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-rela-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    [rela_port, control_port] = free_ports(2)

    bin =
      System.get_env("ATLAS_E2E_RELA_BIN") ||
        Path.join(System.user_home!(), ".local/share/atlas/test/bin")

    settings = %{
      "env" => "test",
      "control" => %{"host" => "127.0.0.1", "port" => control_port},
      "rela" => %{
        "url" => "http://127.0.0.1:#{rela_port}/api/v1",
        "port" => rela_port,
        "data" => Path.join(dir, "rela"),
        "bin" => bin,
        "extra" => "rela/atlas.json"
      },
      "state" => %{"data" => Path.join(dir, "beam")},
      "reconcile_seconds" => 5
    }

    file = Path.join(dir, "test.json")
    File.write!(file, JSON.encode!(settings))

    env = [
      {"ATLAS_ENV_FILE", file},
      {"ATLAS_NO_UPDATE", "1"},
      {"MIX_ENV", "dev"},
      {"ATLAS_RELA_PORT", "#{rela_port}"},
      {"ATLAS_RELA_DATA", Path.join(dir, "rela")},
      {"ATLAS_RELA_BIN", bin},
      {"ATLAS_TEST_ROOT", dir}
    ]

    on_exit(fn ->
      atlas(env, ["stop"])
      atlas(env, ["rela-stop"])
      File.rm_rf!(dir)
    end)

    %{dir: dir, env: env, url: settings["rela"]["url"]}
  end

  defp atlas(env, args),
    do:
      System.cmd(Path.join(@root, "bin/atlas"), args ++ ["--env", "test"],
        env: env,
        stderr_to_stdout: true
      )

  # rela started as the scripts start it, but from a copy of rela/ whose description has
  # one kind more: what an earlier build left running.
  defp start_older_rela(%{dir: dir, env: env}) do
    old = Path.join(dir, "old-rela")
    File.mkdir_p!(old)
    File.cp_r!(Path.join(@root, "rela"), old)

    schema = Path.join(old, "schema.yaml")

    File.write!(
      schema,
      String.replace(File.read!(schema), "\nentities:\n", "\nentities:\n" <> @gone, global: false)
    )

    {out, status} =
      System.cmd(Path.join(old, "scripts/start-bg.sh"), [], env: env, stderr_to_stdout: true)

    assert status == 0, out
  end

  defp kinds(url) do
    {json, 0} = System.cmd("curl", ["-fsS", url <> "/_schema"])
    json |> JSON.decode!() |> Map.fetch!("entities") |> Map.keys()
  end

  defp put(url, plural, id, title) do
    body = JSON.encode!(%{"id" => id, "properties" => %{"title" => title}})

    {_, 0} =
      System.cmd("curl", [
        "-fsS",
        "-X",
        "POST",
        "-H",
        "content-type: application/json",
        "-d",
        body,
        "#{url}/#{plural}"
      ])
  end

  test "rela on an older description is restarted on the build's; its data stays", ctx do
    start_older_rela(ctx)
    assert "e2e_gone" in kinds(ctx.url)
    put(ctx.url, "scenes", "SC-Atlas-01", "Kept across the restart")

    {out, 0} = atlas(ctx.env, ["status"])
    assert out =~ "description: older than this build's; atlas restart --env test restarts rela"

    {out, status} = atlas(ctx.env, ["restart"])
    assert status == 0, out

    assert out =~
             "atlas: rela test ran an older description; restarted it on this build's (its data stays)"

    assert out =~ "atlas: core ready"

    refute "e2e_gone" in kinds(ctx.url)
    {scene, 0} = System.cmd("curl", ["-fsS", ctx.url <> "/scenes/SC-Atlas-01"])
    assert scene =~ "Kept across the restart"

    {out, 0} = atlas(ctx.env, ["status"])
    assert out =~ "description: this build's"

    # Nothing to do the second time.
    {out, 0} = atlas(ctx.env, ["restart"])
    refute out =~ "older description"
  end

  test "a description that would leave data without one is not started: it names it", ctx do
    start_older_rela(ctx)
    put(ctx.url, "e2e_gones", "G-1", "Data of a kind this build no longer has")

    {out, status} = atlas(ctx.env, ["restart"])
    assert status == 1, out

    assert out =~
             "atlas: rela test runs an older description, and this build's no longer describes data it holds:"

    assert out =~ "e2e_gone"
    assert out =~ "then: atlas restart --env test"
    refute out =~ "core ready"

    # rela was left as it was, on its own description, with its data.
    assert "e2e_gone" in kinds(ctx.url)
  end

  defp free_ports(n) do
    sockets = for _ <- 1..n, do: elem(:gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}]), 1)
    ports = Enum.map(sockets, fn s -> elem(:inet.port(s), 1) end)
    Enum.each(sockets, &:gen_tcp.close/1)
    ports
  end
end
