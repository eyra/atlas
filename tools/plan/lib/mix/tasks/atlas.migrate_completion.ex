defmodule Mix.Tasks.Atlas.MigrateCompletion do
  @shortdoc "UC-Atlas-32: completion becomes an association"
  @moduledoc """
      atlas migrate-completion --env <env> [--dry-run]

  (or `mix atlas.migrate_completion ...` in tools/plan). See `AtlasPlan.Completion`. Run
  it with `--dry-run` first: it prints the steps and writes nothing. It reads the history
  file `tools/plan/done_in.json` and rela's old values, and writes through Control.
  """
  use Mix.Task

  @done_in Path.expand("../../../done_in.json", __DIR__)

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [env: :string, dry_run: :boolean])
    env = opts[:env] || "prod"

    status =
      with [] <- invalid,
           {:ok, json} <- File.read(@done_in),
           {:ok, done_in} <- JSON.decode(json),
           {:ok, settings} <- AtlasAgent.settings(env),
           {:ok, client} <- AtlasAgent.connect(env, "migration"),
           {:ok, _} <-
             AtlasPlan.Completion.run(client, settings["rela"]["url"],
               dry_run: opts[:dry_run] || false,
               done_in: Map.drop(done_in, ["_about"])
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
    IO.puts(:stderr, "atlas migrate-completion: " <> text)
    1
  end
end
