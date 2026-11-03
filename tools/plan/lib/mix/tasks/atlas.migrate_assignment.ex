defmodule Mix.Tasks.Atlas.MigrateAssignment do
  @shortdoc "IS-Atlas-78: every assignable fact gets its Assignment, and its owner moves there"
  @moduledoc """
      atlas migrate-assignment --env <env> [--dry-run]

  (`bin/atlas` runs this task twice, around a restart of rela and the core on the new
  description: first with `--keep-origins <file>`, which reads who set each old owner
  through Control and writes nothing, then with `--origins <file>`.) See
  `AtlasPlan.Assignment`. Run it with `--dry-run` first: it prints the steps and writes
  nothing.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [env: :string, dry_run: :boolean, keep_origins: :string, origins: :string]
      )

    env = opts[:env] || "prod"

    status =
      with [] <- invalid,
           {:ok, settings} <- AtlasAgent.settings(env),
           {:ok, client} <- AtlasAgent.connect(env, "migration"),
           {:ok, _} <-
             AtlasPlan.Assignment.run(client, settings["rela"]["url"],
               dry_run: opts[:dry_run] || false,
               read_only: opts[:keep_origins] != nil,
               origins: opts[:keep_origins] || opts[:origins]
             ) do
        0
      else
        {:error, text} when is_binary(text) -> fail(text)
        {:error, other} -> fail(inspect(other))
        _ -> fail(@moduledoc |> String.split("\n") |> Enum.at(0) |> String.trim())
      end

    if status != 0, do: exit({:shutdown, status})
  end

  defp fail(text) do
    IO.puts(:stderr, "atlas migrate-assignment: " <> text)
    1
  end
end
