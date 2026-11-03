defmodule AtlasTui.CLI do
  @moduledoc """
  `mix atlas.tui --env test` (or `bin/atlas tui --env test` from the repository root).

  Connects to Control of one environment. prod is the default and is not built yet.
  Settings come from `env/<env>.json` at the repository root.
  """

  @root Path.expand("../../../..", __DIR__)

  def main(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [env: :string])

    cond do
      invalid != [] ->
        fail("Unknown option(s): #{Enum.map_join(invalid, " ", &elem(&1, 0))}. Use --env test.")

      (opts[:env] || "prod") == "prod" ->
        fail("Atlas prod is not built yet. Start the TUI with --env test.")

      true ->
        env = opts[:env]
        root = System.get_env("ATLAS_ROOT") || @root

        file = System.get_env("ATLAS_ENV_FILE") || Path.join(root, "env/#{env}.json")

        case File.read(file) do
          {:ok, json} -> AtlasTui.App.run(env, JSON.decode!(json))
          {:error, _} -> fail("Atlas has no environment #{inspect(env)} (no env/#{env}.json).")
        end
    end
  end

  defp fail(text) do
    IO.puts(:stderr, text)
    System.halt(1)
  end
end
