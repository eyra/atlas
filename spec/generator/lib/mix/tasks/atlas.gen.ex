defmodule Mix.Tasks.Atlas.Gen do
  @shortdoc "Generate the file targets of the configured contract"
  @moduledoc """
      mix atlas.gen           # write them
      mix atlas.gen --check   # fail when one is stale or left over (CI)

  Run in a contract's project, which configures its contract and file targets:

      config :atlas_spec,
        contract: MyContract,
        targets: [json: "../targets/json"],
        root: "../.."

  `contract` uses `AtlasSpec.Schema`; `targets` maps each file target to its folder;
  `root` (optional, default the project's folder) is what the header's path to the
  contract file is relative to. The
  file targets are `json` (`AtlasSpec.Targets.Json`). Compile-time targets
  (`AtlasSpec.Targets.Server`, `AtlasSpec.Targets.Client`) write no files.

  Every file starts with an `AtlasSpec.Header`. A file without exactly that header is
  hand-written and never overwritten. A file with it, in a target's folder, that no
  target writes any more (a renamed or removed one) is left over: the task removes it,
  and `--check` fails on it, as on a file that would change.
  """
  use Mix.Task

  alias AtlasSpec.Header

  @requirements ["compile"]

  # Every file target has `files/1`: a contract's `__schema__/0` to `[{path, body}]`,
  # paths relative to the target's folder.
  @targets %{json: AtlasSpec.Targets.Json}

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [check: :boolean])
    if rest != [], do: Mix.raise("unexpected argument #{Enum.join(rest, " ")}")

    schema = contract!().__schema__()

    source =
      Path.relative_to(schema.file, Path.expand(Application.get_env(:atlas_spec, :root, ".")))

    files =
      for {target, dir} <- targets!(),
          {path, body} <- Map.fetch!(@targets, target).files(schema),
          do: {Path.join(dir, path), Header.put(Path.extname(path), source, body)}

    stale = for {path, body} <- files, File.read(path) != {:ok, body}, do: path
    leftovers = leftovers(files)

    cond do
      opts[:check] && (stale != [] or leftovers != []) ->
        Mix.raise(
          "out of date, run `mix atlas.gen`: " <>
            Enum.join(stale ++ Enum.map(leftovers, &"#{&1} (left over)"), ", ")
        )

      opts[:check] ->
        Mix.shell().info("generated files are up to date")

      true ->
        for path <- stale,
            File.exists?(path),
            not generated?(path),
            do: Mix.raise("#{path} has no generated header; it is not overwritten")

        for path <- leftovers do
          File.rm!(path)
          Mix.shell().info("removed #{path} (left over)")
        end

        for {path, body} <- files, path in stale do
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, body)
          Mix.shell().info("wrote #{path}")
        end

        if stale == [] and leftovers == [], do: Mix.shell().info("generated files are up to date")
    end
  end

  # Files with the header, in a target's folder, that no target writes now.
  defp leftovers(files) do
    written = Enum.map(files, &elem(&1, 0))

    for {_target, dir} <- targets!(),
        path <- Path.wildcard(Path.join(dir, "**/*")),
        File.regular?(path),
        path not in written,
        generated?(path),
        do: path
  end

  defp generated?(path), do: Header.generated?(Path.extname(path), File.read!(path))

  defp contract! do
    case Application.get_env(:atlas_spec, :contract) do
      nil -> Mix.raise("no contract: set `config :atlas_spec, contract: MyContract`")
      contract -> contract
    end
  end

  defp targets! do
    targets = Application.get_env(:atlas_spec, :targets, [])

    for {target, _dir} <- targets, not Map.has_key?(@targets, target) do
      Mix.raise(
        "unknown target #{inspect(target)}; known: #{inspect(@targets |> Map.keys() |> Enum.sort())}"
      )
    end

    targets
  end
end
