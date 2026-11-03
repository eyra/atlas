defmodule AtlasE2E.Instance do
  @moduledoc """
  A private Atlas test instance for one run: a fresh, empty rela dataset on free ports,
  and the core, both started with the `atlas` command through `ATLAS_ENV_FILE`, always
  with `--env test`, with a stand-in GitHub (`AtlasE2E.GitHub`). It never uses the ports or data of `env/test.json` or
  `env/prod.json` (Melle's instances) or the live store.

  rela's binaries are shared between runs (`ATLAS_E2E_RELA_BIN`, by default the test
  instance's `~/.local/share/atlas/test/bin`); `rela/scripts/start-test.sh` downloads the
  pinned version there when it is missing.
  """

  defstruct [:root, :dir, :file, :settings, :env]

  @root Path.expand("../../..", __DIR__)

  def root, do: @root

  def start do
    dir = Path.join(System.tmp_dir!(), "atlas-e2e-#{System.os_time(:millisecond)}")
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
      "reconcile_seconds" => 5,
      # GitHub is a stand-in (UC-Atlas-26), read every 2 seconds rather than 5 minutes.
      "connectors" => %{
        "github" => %{
          "api" => AtlasE2E.GitHub.start(),
          "token_command" => ["echo", AtlasE2E.GitHub.token()],
          "every_seconds" => 2
        }
      },
      # The planning agent is a scripted stand-in, so no model is needed (UC-Atlas-16).
      "agent" => %{
        "planner" => ["elixir", Path.join(@root, "e2e/fixtures/planner.exs")],
        "name" => "the e2e stand-in"
      }
    }

    file = Path.join(dir, "test.json")
    File.write!(file, JSON.encode!(settings))

    instance = %__MODULE__{
      root: @root,
      dir: dir,
      file: file,
      settings: settings,
      # The core runs as `atlas up` runs it, in Mix's dev environment.
      env: [{"ATLAS_ENV_FILE", file}, {"ATLAS_NO_UPDATE", "1"}, {"MIX_ENV", "dev"}]
    }

    # `atlas restart` starts rela when it does not answer, then the core, and waits for it.
    :ok = atlas!(instance, ["restart", "--env", "test"])
    instance
  end

  @doc "Stop the core, as `atlas stop` does."
  def stop_core(instance), do: atlas!(instance, ["stop", "--env", "test"])

  @doc "Start the core again, as `atlas restart` does."
  def start_core(instance), do: atlas!(instance, ["restart", "--env", "test"])

  def stop(instance) do
    atlas(instance, ["stop", "--env", "test"])
    atlas(instance, ["rela-stop", "--env", "test"])
    :ok
  end

  @doc "The files worth keeping when a run fails: the core's log and rela's."
  def logs(instance),
    do: Path.wildcard(Path.join(instance.dir, "*.log"))

  @doc "GET from rela itself, to check what it stored."
  def rela_get(instance, path) do
    url = String.to_charlist(instance.settings["rela"]["url"] <> path)

    case :httpc.request(:get, {url, []}, [timeout: 5_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> JSON.decode!(body)
      other -> raise "rela did not answer #{path}: #{inspect(other)}"
    end
  end

  defp atlas!(instance, args) do
    case atlas(instance, args) do
      {_, 0} -> :ok
      {out, status} -> raise "atlas #{Enum.join(args, " ")} failed (#{status}):\n#{out}"
    end
  end

  defp atlas(instance, args) do
    System.cmd(Path.join(@root, "bin/atlas"), args,
      env: instance.env,
      stderr_to_stdout: true
    )
  end

  defp free_ports(n) do
    sockets =
      for _ <- 1..n do
        {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: true)
        socket
      end

    ports = Enum.map(sockets, fn s -> elem(:inet.port(s), 1) end)
    Enum.each(sockets, &:gen_tcp.close/1)
    ports
  end
end
