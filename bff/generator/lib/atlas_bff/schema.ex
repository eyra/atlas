defmodule AtlasBFF.Schema do
  @moduledoc """
  The schema of Control's spec, written as a DSL. Inspired by mica-bff's spec format
  (inspiration only, d-0009: nothing is shared with it).

      defmodule MyBlocks do
        use AtlasBFF.Schema

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

        defpage :item, "/k/:kind/:key"
      end

  - `defblock`: a block Control sends and clients render. A page is a flat, ordered list
    of blocks; a block never holds another block.
  - `defmodel`: a value a block field holds (an action, a row, an input).
  - `defmarkup`: a kind of markup. A view model sends content (its blocks, each with an
    id) and markup: entries of a kind that cover the blocks from one id to another, with
    the kind's fields as props. All markup nests (`AtlasBFF.Markup` has the rules).
  - `field`: a snake_case name, a type and `required: true | false` (default `false`).
    Types: `:string`, `:integer`, `:boolean`, a model, or `{:list, type}`.
  - `defpage`: a page the server serves, by name and path. A segment `:name` is a
    parameter (a string); the others are literal. A page always returns a view model; it
    is fetched, never sent to. Where two pages could match one path, the one with a
    literal segment first wins (`/k/:kind/new` over `/k/:kind/:key`), so the order they are
    written in does not matter (`AtlasBFF.Paths`). Each page is also an endpoint: the call
    that fetches it, so a client has one list of what it can call.

  A mistake fails at compile time and points at its line.

  ## The schema as data

  A contract compiles to one function, `__schema__/0`, and the targets read only that,
  never this module's internals (a test checks it):

      %{
        version: "1.0.0",
        file: "/abs/path/to/the/contract.ex",
        models: [entry],
        blocks: [entry],
        markup: [entry],
        pages: [%{name: atom, path: "/k/:kind/:key", params: [:kind, :key]}],
        endpoints: [%{name: atom, call: :open, page: atom, path: path, params: [atom],
                      returns: :view_model}]
      }

  where an entry is `%{name: atom, fields: [%{name: atom, type: type, required: boolean}]}`
  in the order written, and a type is `:string`, `:integer`, `:boolean`, a model's name,
  or `{:list, type}`. Pages and endpoints are in the order written; an endpoint `:open` is
  the fetch of the page it names.
  """

  @primitives [:string, :integer, :boolean]

  defmacro __using__(_opts) do
    quote do
      import AtlasBFF.Schema,
        only: [
          version: 1,
          defblock: 2,
          defmodel: 2,
          defmarkup: 2,
          defpage: 2,
          field: 2,
          field: 3
        ]

      Module.register_attribute(__MODULE__, :spec_entries, accumulate: true)
      @before_compile AtlasBFF.Schema
    end
  end

  defmacro version(version) do
    quote do: @spec_version(unquote(version))
  end

  defmacro defblock(name, do: body), do: entry(:block, name, body, __CALLER__.line)
  defmacro defmodel(name, do: body), do: entry(:model, name, body, __CALLER__.line)
  defmacro defmarkup(name, do: body), do: entry(:markup, name, body, __CALLER__.line)

  defmacro defpage(name, path) do
    line = __CALLER__.line

    quote do
      if open = Module.get_attribute(__MODULE__, :spec_open) do
        AtlasBFF.Schema.__fail__(
          __ENV__.file,
          unquote(line),
          "page #{inspect(unquote(name))} inside #{inspect(open)}"
        )
      end

      @spec_entries %{type: :page, name: unquote(name), path: unquote(path), line: unquote(line)}
    end
  end

  defp entry(type, name, body, line) do
    quote do
      if open = Module.get_attribute(__MODULE__, :spec_open) do
        AtlasBFF.Schema.__fail__(
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
        AtlasBFF.Schema.__fail__(
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

    {pages, entries} = Enum.split_with(entries, &(&1.type == :page))
    validate!(entries, env.file)
    pages = validate_pages!(pages, env.file)

    strip = fn entry ->
      %{name: entry.name, fields: Enum.map(entry.fields, &Map.delete(&1, :line))}
    end

    spec = %{
      version: version,
      file: env.file,
      models: for(%{type: :model} = e <- entries, do: strip.(e)),
      blocks: for(%{type: :block} = e <- entries, do: strip.(e)),
      markup: for(%{type: :markup} = e <- entries, do: strip.(e)),
      pages: pages,
      endpoints:
        for(
          page <- pages,
          do: %{
            name: page.name,
            call: :open,
            page: page.name,
            path: page.path,
            params: page.params,
            returns: :view_model
          }
        )
    }

    quote do
      @doc "The schema as plain data, for the targets (see `AtlasBFF.Schema`)."
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

  # Pages are a namespace of their own: a page may share its name with a block.
  defp validate_pages!(pages, file) do
    {pages, _seen} =
      Enum.map_reduce(pages, %{}, fn page, seen ->
        fail = &__fail__(file, page.line, &1)
        unless snake?(page.name), do: fail.("page #{inspect(page.name)} is not a snake_case atom")
        if Map.has_key?(seen, page.name), do: fail.("page #{inspect(page.name)} is defined twice")

        segments =
          case AtlasBFF.Paths.parse(page.path) do
            {:ok, segments} -> segments
            {:error, why} -> fail.("page #{inspect(page.name)}: #{why}")
          end

        shape = AtlasBFF.Paths.shape(segments)

        case Enum.find(seen, fn {_name, other} -> other == shape end) do
          {other, _} ->
            fail.("pages #{inspect(other)} and #{inspect(page.name)} match the same paths")

          nil ->
            :ok
        end

        params = for {:param, name} <- segments, do: name
        {%{name: page.name, path: page.path, params: params}, Map.put(seen, page.name, shape)}
      end)

    pages
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
