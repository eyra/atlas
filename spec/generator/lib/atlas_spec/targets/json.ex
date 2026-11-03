defmodule AtlasSpec.Targets.Json do
  @moduledoc """
  A file target: the contract as one JSON file, `blocks.json`, for clients in languages
  other than Elixir. Keys are sorted and indented by two, so diffs stay small.
  """

  alias AtlasSpec.Names

  @doc "`[{path, body}]`, paths relative to the target's folder."
  def files(schema) do
    markup = Names.markup()

    entry = fn e ->
      %{
        "name" => Atom.to_string(e.name),
        "fields" =>
          Enum.map(e.fields, fn f ->
            %{"name" => Atom.to_string(f.name), "type" => type(f.type), "required" => f.required}
          end)
      }
    end

    body =
      %{
        "version" => schema.version,
        "wire" => %{
          "block" => ~s({"id": "<id>", "type": "<block>", "props": {...}}),
          markup =>
            ~s({"kind": "<kind>", "start": "<block id>", "end": "<block id>", "group": "<id, on a piece of split #{markup}>", "props": {...}}),
          to_string(Names.view_model_fun()) =>
            ~s({"blocks": [<block>], "#{markup}": [<#{markup}>]}; all #{markup} nests),
          "props" => "an optional prop without a value is left out"
        },
        "models" => Enum.map(schema.models, entry),
        "blocks" => Enum.map(schema.blocks, entry),
        markup => Enum.map(schema.markup, entry)
      }
      |> pretty()

    [{"blocks.json", body}]
  end

  defp type({:list, inner}), do: "list of " <> type(inner)
  defp type(type), do: Atom.to_string(type)

  defp pretty(value), do: IO.iodata_to_binary(pretty(value, 0)) <> "\n"

  defp pretty(map, level) when is_map(map) do
    inner =
      map
      |> Enum.sort()
      |> Enum.map(fn {k, v} ->
        [indent(level + 1), JSON.encode!(k), ": ", pretty(v, level + 1)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", inner, "\n", indent(level), "}"]
  end

  defp pretty([], _level), do: "[]"

  defp pretty(list, level) when is_list(list) do
    inner =
      list |> Enum.map(&[indent(level + 1), pretty(&1, level + 1)]) |> Enum.intersperse(",\n")

    ["[\n", inner, "\n", indent(level), "]"]
  end

  defp pretty(value, _level), do: JSON.encode!(value)

  defp indent(level), do: String.duplicate("  ", level)
end
