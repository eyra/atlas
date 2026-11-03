defmodule AtlasState.Description do
  @moduledoc """
  Reads rela's description (`GET /_schema`) generically: which kinds exist, their
  properties, and the relations that point at them. Knows no kind by name.
  """

  @doc "The description of `kind`, or nil when rela does not describe it."
  def kind(description, kind), do: get_in(description, ["entities", kind])

  @doc "The relations whose facts point at a fact of `kind`: `[{relation, from_kind}]`."
  def incoming(description, kind) do
    for {relation, spec} <- description["relations"] || %{},
        kind in (spec["to"] || []),
        from <- spec["from"] || [],
        do: {relation, from}
  end

  @doc """
  Check `values` against the description of `kind` before rela sees them, because the
  current rela stores invalid values and only warns. `mode` is `:create` or `:change`.
  `nil` clears an optional value.
  """
  def check(spec, values, mode) do
    properties = spec["properties"] || %{}

    problems =
      Enum.flat_map(values, fn {name, value} -> check_value(properties[name], name, value) end) ++
        missing(properties, values, mode)

    if problems == [], do: :ok, else: {:error, problems}
  end

  @doc "A key that fits the kind's id prefix, if it has one."
  def check_key(spec, key) do
    prefixes = spec["id_prefixes"] || List.wrap(spec["id_prefix"])

    cond do
      not is_binary(key) or String.trim(key) == "" ->
        {:error, ["id is missing"]}

      prefixes != [] and not Enum.any?(prefixes, &String.starts_with?(key, &1)) ->
        {:error, ["id must start with #{Enum.join(prefixes, " or ")}"]}

      true ->
        :ok
    end
  end

  defp missing(properties, values, mode) do
    for {name, %{"required" => true}} <- properties,
        mode == :create or Map.has_key?(values, name),
        blank?(values[name]),
        do: "#{name} is required"
  end

  defp check_value(nil, name, _value), do: ["#{name} is not described"]
  defp check_value(_spec, _name, nil), do: []

  defp check_value(%{"values" => allowed}, name, value) when is_list(allowed) do
    if value in allowed, do: [], else: ["#{name} must be one of #{Enum.join(allowed, ", ")}"]
  end

  defp check_value(%{"type" => "boolean"}, name, value),
    do: if(is_boolean(value), do: [], else: ["#{name} must be true or false"])

  defp check_value(%{"type" => "integer"}, name, value),
    do: if(is_integer(value), do: [], else: ["#{name} must be a whole number"])

  defp check_value(_spec, name, value),
    do: if(is_binary(value), do: [], else: ["#{name} must be text"])

  defp blank?(value), do: value in [nil, ""]
end
