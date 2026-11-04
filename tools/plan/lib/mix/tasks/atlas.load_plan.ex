defmodule Mix.Tasks.Atlas.LoadPlan do
  @shortdoc "UC-Atlas-05: load SCENES.md into Atlas through Control"
  @moduledoc """
      atlas load-plan --env <env> <SCENES.md> <links.json> [--dry-run]

  (or `mix atlas.load_plan ...` in tools/plan). See `AtlasPlan`. Run it with `--dry-run`
  first: it prints what it would create, the stages and links, and the mapping of
  SCENES.md's codes to Atlas's, and writes nothing.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    {opts, files, invalid} = OptionParser.parse(args, strict: [env: :string, dry_run: :boolean])

    status =
      with [] <- invalid,
           [scenes, links] <- files,
           {:ok, text} <- read(scenes),
           {:ok, json} <- read(links),
           {:ok, links} <- JSON.decode(json),
           {:ok, client} <- AtlasAgent.connect(opts[:env] || "prod"),
           {:ok, _result} <- AtlasPlan.run(client, text, links, dry_run: opts[:dry_run] || false) do
        0
      else
        {:error, text} when is_binary(text) -> fail(text)
        {:error, other} -> fail(inspect(other))
        _ -> fail(@moduledoc |> String.split("\n") |> Enum.at(0) |> String.trim())
      end

    if status != 0, do: exit({:shutdown, status})
  end

  defp read(path) do
    case path |> Path.expand(AtlasAgent.caller_cwd()) |> File.read() do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp fail(text) do
    IO.puts(:stderr, "atlas load-plan: " <> text)
    1
  end
end
