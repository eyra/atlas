defmodule Mix.Tasks.Atlas.Gen do
  @shortdoc "Generate Control's server and client block code from the spec"
  @moduledoc """
  Writes the files `AtlasControl.Spec.Gen` makes from Control's spec.

      mix atlas.gen           # write them
      mix atlas.gen --check   # fail when one is out of date (CI)
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    check? = "--check" in args
    root = AtlasControl.Spec.Gen.root()

    stale =
      for {path, content} <- AtlasControl.Spec.Gen.files(),
          full = Path.join(root, path),
          File.read(full) != {:ok, content} do
        unless check? do
          File.mkdir_p!(Path.dirname(full))
          File.write!(full, content)
          Mix.shell().info("wrote #{path}")
        end

        path
      end

    cond do
      check? and stale != [] ->
        Mix.raise("out of date, run `mix atlas.gen`: #{Enum.join(stale, ", ")}")

      stale == [] ->
        Mix.shell().info("generated code is up to date")

      true ->
        :ok
    end
  end
end
