defmodule AtlasSpec.Schema do
  @moduledoc """
  The schema of Control's spec, written as a DSL. Inspired by mica-bff's spec format
  (inspiration only, d-0009: nothing is shared with it).

      defmodule MyBlocks do
        use AtlasSpec.Schema

        version "0.1.0"

        defmodel :action do
          field :label, :string, required: true
        end

        defblock :list do
          field :title, :string, required: true
          field :actions, {:list, :action}
        end

        defmarkup :section do
          field :title, :string, required: true
        end
      end

  - `defblock`: a block Control sends and clients render. A page is a flat, ordered list
    of blocks; a block never holds another block.
  - `defmodel`: a value a block field holds (an action, a row, an input).
  - `defmarkup`: a kind of markup. A view model sends content (its blocks, each with an
    id) and markup: entries of a kind that cover the blocks from one id to another, with
    the kind's fields as props. All markup nests (`AtlasSpec.Markup` has the rules).
  - `field`: a snake_case name, a type and `required: true | false` (default `false`).
    Types: `:string`, `:integer`, `:boolean`, a model, or `{:list, type}`.

  A mistake fails at compile time and points at its line.

  ## The schema as data

  A contract compiles to one function, `__schema__/0`, and the targets read only that,
  never this module's internals (a test checks it):

      %{
        version: "1.0.0",
        file: "/abs/path/to/the/contract.ex",
        models: [entry],
        blocks: [entry],
        markup: [entry]
      }

  where an entry is `%{name: atom, fields: [%{name: atom, type: type, required: boolean}]}`
  in the order written, and a type is `:string`, `:integer`, `:boolean`, a model's name,
  or `{:list, type}`.
  """

  @primitives [:string, :integer, :boolean]

  defmacro __using__(_opts) do
    quote do
      import AtlasSpec.Schema,
        only: [version: 1, defblock: 2, defmodel: 2, defmarkup: 2, field: 2, field: 3]

      Module.register_attribute(__MODULE__, :spec_entries, accumulate: true)
      @before_compile AtlasSpec.Schema
    end
  end

  defmacro version(version) do
    quote do: @spec_version(unquote(version))
  end

  defmacro defblock(name, do: body), do: entry(:block, name, body, __CALLER__.line)
  defmacro defmodel(name, do: body), do: entry(:model, name, body, __CALLER__.line)
  defmacro defmarkup(name, do: body), do: entry(:markup, name, body, __CALLER__.line)

  defp entry(type, name, body, line) do
    quote do
      if open = Module.get_attribute(__MODULE__, :spec_open) do
        AtlasSpec.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "#{inspect(unquote(name))} inside #{inspect(open)}"
        )
      end

      Module.put_attribute(__MODULE__, :spec_open, unquote(name))
      Module.register_attribute(__MODULE__, :spec_fields, accumulate: true)
      unquote(body)

      @spec_entries %{
        type: unquote(type),
        name: unquote(name),
        line: unquote(line),
        fields: Enum.reverse(Module.get_attribute(__MODULE__, :spec_fields))
      }

      Module.delete_attribute(__MODULE__, :spec_fields)
      Module.delete_attribute(__MODULE__, :spec_open)
    end
  end

  defmacro field(name, type, opts \\ []) do
    line = __CALLER__.line

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:required] == [] and
             is_boolean(Keyword.get(opts, :required, false)) do
      __fail__(
        __CALLER__.file,
        line,
        "field #{inspect(name)}: the only option is required: true | false"
      )
    end

    quote do
      unless Module.get_attribute(__MODULE__, :spec_open) do
        AtlasSpec.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "field #{inspect(unquote(name))} outside a block, model or markup"
        )
      end

      @spec_fields %{
        name: unquote(name),
        type: unquote(type),
        required: unquote(Keyword.get(opts, :required, false)),
        line: unquote(line)
      }
    end
  end

  @doc false
  def __fail__(file, line, description),
    do: raise(CompileError, file: file, line: line, description: description)

  defmacro __before_compile__(env) do
    entries = env.module |> Module.get_attribute(:spec_entries) |> Enum.reverse()

    version =
      Module.get_attribute(env.module, :spec_version) ||
        __fail__(env.file, 1, "the spec needs a version")

    validate!(entries, env.file)

    strip = fn entry ->
      %{name: entry.name, fields: Enum.map(entry.fields, &Map.delete(&1, :line))}
    end

    spec = %{
      version: version,
      file: env.file,
      models: for(%{type: :model} = e <- entries, do: strip.(e)),
      blocks: for(%{type: :block} = e <- entries, do: strip.(e)),
      markup: for(%{type: :markup} = e <- entries, do: strip.(e))
    }

    quote do
      @doc "The schema as plain data, for the targets (see `AtlasSpec.Schema`)."
      def __schema__, do: unquote(Macro.escape(spec))
    end
  end

  defp validate!(entries, file) do
    names = fn type -> for %{type: ^type, name: name} <- entries, do: name end
    kinds = {names.(:model), names.(:block), names.(:markup)}

    Enum.reduce(entries, MapSet.new(), fn entry, seen ->
      fail = &__fail__(file, entry.line, &1)
      unless snake?(entry.name), do: fail.("#{inspect(entry.name)} is not a snake_case atom")
      if entry.name in seen, do: fail.("#{inspect(entry.name)} is defined twice")

      if entry.name in @primitives,
        do: fail.("#{inspect(entry.name)} clashes with a primitive type")

      Enum.reduce(entry.fields, MapSet.new(), fn field, names ->
        fail = &__fail__(file, field.line, &1)

        unless snake?(field.name),
          do: fail.("field #{inspect(field.name)} is not a snake_case atom")

        if field.name in names,
          do: fail.("#{inspect(entry.name)} has field #{inspect(field.name)} twice")

        check_type!(field.type, kinds, "#{entry.name}.#{field.name}", fail)
        MapSet.put(names, field.name)
      end)

      MapSet.put(seen, entry.name)
    end)
  end

  defp check_type!({:list, inner}, kinds, at, fail), do: check_type!(inner, kinds, at, fail)
  defp check_type!(type, _kinds, _at, _fail) when type in @primitives, do: :ok

  defp check_type!(type, {models, blocks, markup}, at, fail) do
    cond do
      type in models -> :ok
      type in blocks -> fail.("#{at} holds block #{inspect(type)}; blocks have no children")
      type in markup -> fail.("#{at} holds markup #{inspect(type)}; markup covers blocks")
      true -> fail.("#{at} has unknown type #{inspect(type)}")
    end
  end

  defp snake?(name),
    do: is_atom(name) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name))
end
