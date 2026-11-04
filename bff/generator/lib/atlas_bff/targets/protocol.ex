defmodule AtlasBFF.Targets.Protocol do
  @moduledoc """
  Compile-time payload and path target consuming only `__schema__/0`.

  `payload/3` validates `takes` and returns string-keyed JSON data. Optional nil
  fields are omitted. `message/3` adds `op` for explicitly chosen pathless calls.
  Optional wire descriptors supply channel/direction, request envelopes and reply
  selectors to `request/3` and `classify/3`. Sockets, deadlines, adapters and
  permissions remain the caller's responsibility.
  """
  defmacro __using__(opts) do
    schema = Macro.expand(opts[:contract], __CALLER__).__schema__()

    AtlasBFF.Wire.validate!(schema)

    quote do
      @protocol_wires unquote(Macro.escape(Map.get(schema, :protocol, [])))
      @protocol_models unquote(Macro.escape(Map.new(schema.models, &{&1.name, &1.fields})))
      @protocol_pages unquote(Macro.escape(schema.pages))
      @protocol_endpoints unquote(Macro.escape(schema.endpoints))
      def version, do: unquote(schema.version)
      def pages, do: @protocol_pages
      def endpoints, do: @protocol_endpoints
      def path(name, params \\ %{}), do: AtlasBFF.Paths.build(@protocol_pages, name, params)
      def match(path), do: AtlasBFF.Paths.match(@protocol_pages, path)

      def wires, do: @protocol_wires

      def request(name, props \\ %{}, channel \\ unquote(opts[:channel])) do
        wire = AtlasBFF.Wire.descriptor!(@protocol_wires, name, channel)
        AtlasBFF.Wire.encode!(wire, props)
      end

      def classify(name, message, channel \\ unquote(opts[:channel])),
        do: AtlasBFF.Wire.classify(@protocol_wires, name, channel, message)

      def endpoint_path(call, name, params \\ %{}) do
        endpoint = AtlasBFF.Targets.Protocol.endpoint!(@protocol_endpoints, call, name)
        if endpoint.path, do: AtlasBFF.Paths.build([endpoint], name, params)
      end

      def payload(call, name, props \\ %{}) do
        endpoint = AtlasBFF.Targets.Protocol.endpoint!(@protocol_endpoints, call, name)
        AtlasBFF.Targets.Protocol.payload!(@protocol_models, endpoint.takes, props)
      end

      def message(call, name, props \\ %{}) do
        endpoint = AtlasBFF.Targets.Protocol.endpoint!(@protocol_endpoints, call, name)
        if endpoint.path, do: raise(ArgumentError, "path endpoint requires a transport envelope")

        if @protocol_wires == [] do
          Map.put(payload(call, name, props), "op", Atom.to_string(endpoint.call))
        else
          request(endpoint.wire, payload(call, name, props))
        end
      end
    end
  end

  @doc false
  def endpoint!(endpoints, call, name) do
    Enum.find(endpoints, &(&1.call == call and &1.name == name)) ||
      raise ArgumentError, "no endpoint #{inspect(name)} (#{call})"
  end

  @doc false
  def payload!(models, nil, props), do: model!(models, "payload", [], props)
  def payload!(models, :values, props), do: value!(models, {:map, :string}, props)
  def payload!(models, name, props), do: model!(models, name, Map.fetch!(models, name), props)

  defp model!(models, name, fields, props) when is_map(props) or is_list(props) do
    props = Map.new(props, fn {key, value} -> {to_string(key), value} end)
    known = Enum.map(fields, &Atom.to_string(&1.name))

    if Map.keys(props) -- known != [],
      do: raise(ArgumentError, "#{name} has unknown fields #{inspect(Map.keys(props) -- known)}")

    Enum.reduce(fields, %{}, fn field, acc ->
      key = Atom.to_string(field.name)

      case Map.get(props, key) do
        nil when field.required -> raise ArgumentError, "#{name}.#{key} is required"
        nil -> acc
        value -> Map.put(acc, key, value!(models, field.type, value))
      end
    end)
  end

  defp model!(_models, name, _fields, _props),
    do: raise(ArgumentError, "#{name} must be an object")

  defp value!(_models, :string, value) when is_binary(value), do: value
  defp value!(_models, :integer, value) when is_integer(value), do: value
  defp value!(_models, :boolean, value) when is_boolean(value), do: value

  defp value!(models, {:list, type}, values) when is_list(values),
    do: Enum.map(values, &value!(models, type, &1))

  defp value!(models, {:map, type}, values) when is_map(values),
    do: Map.new(values, fn {key, value} -> {to_string(key), value!(models, type, value)} end)

  defp value!(models, type, value) when is_map_key(models, type),
    do: model!(models, type, Map.fetch!(models, type), value)

  defp value!(_models, type, value),
    do: raise(ArgumentError, "expected #{inspect(type)}, got: #{inspect(value)}")
end
