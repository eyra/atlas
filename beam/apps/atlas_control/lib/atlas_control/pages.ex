defmodule AtlasControl.Pages do
  @moduledoc """
  Turns rela's description and facts into pages of blocks. Knows no kind by name: every
  title, field, choice and rule comes from the description.

  Paths:

  | Path                      | Page                                              |
  |---------------------------|---------------------------------------------------|
  | `/`                       | the top kinds; the list itself when there is one  |
  | `/k/<kind>`               | list of facts of a kind                           |
  | `/k/<kind>/new`           | form to create one                                |
  | `/k/<kind>/new/<rel>/<p>` | form to create one that points at `p` via `rel`   |
  | `/k/<kind>/<key>`         | one fact, with a list per relation pointing at it |
  | `/k/<kind>/<key>/edit`    | form to change it                                 |
  | `/k/<kind>/<key>/delete`  | confirm deleting it, or why it cannot be deleted  |

  A top kind is one that does not belong to a parent: it is not the `from` of a relation
  with `max_outgoing: 1`. Kinds that belong to a parent are reached through it: a fact's
  page lists the facts that point at it, and adds new ones already pointing at it.
  """

  require AtlasControl.Blocks, as: Blocks

  # Keys for the "add" action of each related list on a page, in order.
  @add_keys ~w(a s x z)

  # Routes

  def route("/"), do: :home

  def route(path) do
    case path |> String.trim_leading("/") |> String.split("/") |> Enum.map(&URI.decode/1) do
      ["k", kind] -> {:list, kind}
      ["k", kind, "new"] -> {:new, kind}
      ["k", kind, "new", relation, parent] -> {:new, kind, {relation, parent}}
      ["k", kind, key] -> {:item, kind, key}
      ["k", kind, key, "edit"] -> {:edit, kind, key}
      ["k", kind, key, "delete"] -> {:delete, kind, key}
      _ -> :unknown
    end
  end

  def path({:list, kind}), do: "/k/#{enc(kind)}"
  def path({:new, kind}), do: "/k/#{enc(kind)}/new"

  def path({:new, kind, {relation, parent}}),
    do: "/k/#{enc(kind)}/new/#{enc(relation)}/#{enc(parent)}"

  def path({:item, kind, key}), do: "/k/#{enc(kind)}/#{enc(key)}"
  def path({:edit, kind, key}), do: "/k/#{enc(kind)}/#{enc(key)}/edit"
  def path({:delete, kind, key}), do: "/k/#{enc(kind)}/#{enc(key)}/delete"

  defp enc(part), do: URI.encode(part, &URI.char_unreserved?/1)

  @doc "The kind a route is about."
  def kind_of(:home), do: :all
  def kind_of(:unknown), do: nil
  def kind_of(route), do: elem(route, 1)

  @doc "Whether a hint of `kind` can change what `route` shows."
  def shows?(:home, _description, _kind), do: true

  def shows?({page, of, _key} = route, description, kind) when page in [:item, :delete],
    do: kind == kind_of(route) or kind in Enum.map(child_relations(description, of), &elem(&1, 1))

  def shows?(route, _description, kind), do: kind == kind_of(route)

  def form?(route), do: elem_match?(route, [:new, :edit])

  defp elem_match?(route, pages), do: is_tuple(route) and elem(route, 0) in pages

  @doc "The relations whose facts point at `kind`: `[{relation, from kind, spec}]`."
  def child_relations(description, kind) do
    for {relation, %{"to" => to, "from" => [from]} = spec} <-
          Enum.sort(description["relations"] || %{}),
        kind in to,
        do: {relation, from, spec}
  end

  @doc "The reads a route needs: `[{kind, content}]`."
  def reads(:home, description) do
    case top_kinds(description) do
      [kind] -> reads({:list, kind}, description)
      _ -> []
    end
  end

  def reads({:list, kind}, _), do: [{kind, %{}}]
  def reads({:new, _}, _), do: []
  def reads({:new, _, _}, _), do: []

  def reads({:item, kind, key}, description) do
    children =
      for {relation, from, _} <- child_relations(description, kind),
          do: {from, %{"linked" => %{relation => key}}}

    [{kind, %{"key" => key}} | children]
  end

  def reads({_, kind, key}, _), do: [{kind, %{"key" => key}}]
  def reads(:unknown, _), do: []

  def top_kinds(description) do
    children =
      for {_name, %{"max_outgoing" => 1, "from" => from}} <- description["relations"] || %{},
          kind <- from,
          do: kind

    description |> Map.get("entities", %{}) |> Map.keys() |> Kernel.--(children) |> Enum.sort()
  end

  # Pages

  @doc """
  The page for `route`: `%{title, back, blocks}`. `answers` are State's answers to
  `reads/2`, in order. `form` carries values and errors to show a form again.
  """
  def render(route, description, answers, form \\ %{})

  def render(:home, description, answers, form) do
    case top_kinds(description) do
      [kind] -> %{render({:list, kind}, description, answers, form) | back: nil}
      kinds -> home(description, kinds)
    end
  end

  def render(route, description, answers, form) do
    kind = kind_of(route)

    case kind && Map.get(description["entities"] || %{}, kind) do
      nil -> missing("Nothing here", "This page does not exist (any more).", "/")
      spec -> page(route, kind, spec, description, answers, form)
    end
  end

  defp home(description, kinds) do
    rows =
      for kind <- kinds do
        spec = description["entities"][kind]

        Blocks.row(
          label: plural(spec, kind),
          detail: spec["description"] |> first_line(),
          to: path({:list, kind})
        )
      end

    page("Atlas", nil, [
      Blocks.list(title: "Atlas", rows: rows, empty: "rela describes nothing yet")
    ])
  end

  defp page({:list, kind}, kind, spec, description, [answer], _form) do
    case answer do
      %{"facts" => facts} ->
        rows =
          facts
          |> Enum.sort_by(& &1["key"])
          |> Enum.map(fn fact ->
            Blocks.row(
              label: label(spec, fact),
              detail: detail(spec, fact),
              to: path({:item, kind, fact["key"]})
            )
          end)

        list =
          Blocks.list(
            title: plural(spec, kind),
            rows: rows,
            empty: "No #{String.downcase(plural(spec, kind))} yet. Press n to make one.",
            actions: [
              Blocks.action(
                label: "New #{singular(spec, kind) |> String.downcase()}",
                key: "n",
                to: path({:new, kind})
              )
            ]
          )

        # The only top kind's list is the start page; there is nothing to go back to.
        back = if top_kinds(description) == [kind], do: nil, else: "/"
        page(plural(spec, kind), back, [list])

      %{"error" => error} ->
        unavailable(error, "/")
    end
  end

  defp page({:item, kind, key}, kind, spec, description, [answer | child_answers], _form) do
    case answer do
      %{"fact" => nil} ->
        missing(
          "#{singular(spec, kind)} #{key}",
          "#{key} does not exist (any more).",
          path({:list, kind})
        )

      %{"fact" => fact} ->
        back = path(up(description, kind, fact))

        fields =
          [Blocks.pair(label: "Id", value: key)] ++
            Enum.flat_map(ordered(spec), fn {name, prop} ->
              value = fact["values"][name]

              # A field only a connector or the system fills shows only once it has a value.
              if settable?(prop) or value not in [nil, ""],
                do: [Blocks.pair(label: humanize(name), value: show(prop, value))],
                else: []
            end) ++
            Enum.map(parents(description, kind, fact), fn {label, keys} ->
              Blocks.pair(label: label, value: Enum.join(keys, ", "))
            end)

        item =
          Blocks.item(
            title: "#{singular(spec, kind)} #{key}: #{label(spec, fact)}",
            fields: fields,
            actions: [
              Blocks.action(label: "Change", key: "e", to: path({:edit, kind, key})),
              Blocks.action(label: "Delete", key: "d", to: path({:delete, kind, key}))
            ]
          )

        lists =
          description
          |> child_relations(kind)
          |> Enum.zip(child_answers)
          |> Enum.zip(@add_keys)
          |> Enum.map(fn {{{relation, from, rel_spec}, child_answer}, add_key} ->
            {"list:" <> relation,
             child_list(description, {relation, from, rel_spec}, key, child_answer, add_key)}
          end)

        # The fact in a border; each related list in a section that carries its title.
        markup =
          [Blocks.border("item", "item")] ++
            for {id, {title, _list}} <- lists, do: Blocks.section(id, id, title: title)

        content = [{"item", item} | for({id, {_title, list}} <- lists, do: {id, list})]
        page("#{singular(spec, kind)} #{key}", back, content, markup)

      %{"error" => error} ->
        unavailable(error, path({:list, kind}))
    end
  end

  defp page({:new, kind, {_relation, parent}} = route, kind, spec, description, [], form) do
    %{blocks: [form_block]} = page({:new, kind}, kind, spec, description, [], form)
    parent_route = {:item, parent_kind(description, route), parent}
    title = "New #{singular(spec, kind) |> String.downcase()} in #{parent}"

    form_block =
      form_block
      |> put_in(["props", "title"], title)
      |> put_in(["props", "submit_to"], path(route))
      |> put_in(["props", "cancel_to"], path(parent_route))

    page(title, path(parent_route), [form_block])
  end

  # A create asks only what the kind's create rule asks; the id is made, never typed.
  defp page({:new, kind}, kind, spec, _description, [], form) do
    values = form[:values] || %{}
    asked = create_rule(spec).ask

    form_block =
      Blocks.form(
        title: "New #{singular(spec, kind) |> String.downcase()}",
        inputs: inputs(spec, values, only: asked),
        submit_label: "Create",
        submit_to: path({:new, kind}),
        cancel_to: path({:list, kind}),
        errors: form[:errors] || []
      )

    page("New #{singular(spec, kind) |> String.downcase()}", path({:list, kind}), [form_block])
  end

  defp page({:edit, kind, key}, kind, spec, _description, [answer], form) do
    back = path({:item, kind, key})

    case answer do
      %{"fact" => nil} ->
        missing("Change #{key}", "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} ->
        shown = Map.new(fact["values"] || %{}, fn {k, v} -> {k, to_text(v)} end)
        values = Map.merge(shown, form[:values] || %{})

        form_block =
          Blocks.form(
            title: "Change #{singular(spec, kind) |> String.downcase()} #{key}",
            # The id is shown, never changed.
            inputs: [
              Blocks.input(name: "_key", label: "Id", kind: "readonly", value: key)
              | inputs(spec, values)
            ],
            submit_label: "Save",
            submit_to: path({:edit, kind, key}),
            cancel_to: back,
            errors: form[:errors] || []
          )

        page("Change #{key}", back, [form_block])

      %{"error" => error} ->
        unavailable(error, back)
    end
  end

  defp page({:delete, kind, key}, kind, spec, description, [answer], _form) do
    back = path({:item, kind, key})

    case answer do
      %{"fact" => nil} ->
        missing("Delete #{key}", "#{key} does not exist (any more).", path({:list, kind}))

      %{"fact" => fact} = answer ->
        case Enum.reject(children(description, kind, answer), fn {_, keys} -> keys == [] end) do
          [] ->
            confirm =
              Blocks.confirm(
                title: "Delete #{singular(spec, kind) |> String.downcase()} #{key}?",
                text: "#{key}: #{label(spec, fact)} will be deleted. This cannot be undone.",
                confirm_label: "Delete",
                confirm_to: path({:delete, kind, key}),
                cancel_to: back
              )

            page("Delete #{key}", back, [confirm])

          held ->
            what =
              Enum.map_join(held, " and ", fn {label, keys} ->
                count(keys) <> " " <> String.downcase(label)
              end)

            confirm =
              Blocks.confirm(
                title: "#{key} cannot be deleted",
                text:
                  "#{key} still has #{what}. Remove them first; Atlas never deletes them along with it.",
                cancel_to: back
              )

            page("Delete #{key}", back, [confirm])
        end

      %{"error" => error} ->
        unavailable(error, back)
    end
  end

  defp page(_route, _kind, _spec, _description, _answers, _form),
    do: missing("Nothing here", "This page does not exist.", "/")

  # The view model of a page. A block without an id of its own is named by its type; a
  # page holds at most one such block of each type.
  defp page(title, back, content, markup \\ []) do
    content =
      Enum.map(content, fn
        {id, block} -> {id, block}
        block -> {block["type"], block}
      end)

    Map.merge(%{title: title, back: back}, Blocks.view_model(content, markup))
  end

  defp child_list(description, {relation, from, rel_spec}, key, answer, add_key) do
    from_spec = description["entities"][from] || %{}
    title = String.capitalize(get_in(rel_spec, ["inverse", "label"]) || plural(from_spec, from))
    name = singular(from_spec, from) |> String.downcase()

    rows =
      case answer do
        %{"facts" => facts} ->
          facts
          |> Enum.sort_by(& &1["key"])
          |> Enum.map(
            &Blocks.row(
              label: label(from_spec, &1),
              detail: detail(from_spec, &1),
              to: path({:item, from, &1["key"]})
            )
          )

        _ ->
          []
      end

    empty =
      case answer do
        %{"error" => error} -> "#{error}."
        _ -> "No #{String.downcase(title)} yet. Press #{add_key} to add one."
      end

    {title,
     Blocks.list(
       rows: rows,
       empty: empty,
       actions: [
         Blocks.action(
           label: "Add #{name}",
           key: add_key,
           to: path({:new, from, {relation, key}})
         )
       ]
     )}
  end

  @doc "Where to go after a fact of `kind` is deleted: its parent, or the list of its kind."
  def after_delete(description, kind, %{"fact" => fact}) when is_map(fact),
    do: up(description, kind, fact)

  def after_delete(_description, kind, _answer), do: {:list, kind}

  # A fact's parent page, when it points at one through an at-most-one relation.
  defp up(description, kind, fact) do
    parent =
      Enum.find_value(description["relations"] || %{}, fn {relation, spec} ->
        with true <- kind in (spec["from"] || []) and spec["max_outgoing"] == 1,
             [to] <- spec["to"],
             [parent_key] <- get_in(fact, ["links", relation]) do
          {:item, to, parent_key}
        else
          _ -> nil
        end
      end)

    parent || {:list, kind}
  end

  # The facts this one points at: `[{label, keys}]`.
  defp parents(description, kind, fact) do
    for {relation, spec} <- Enum.sort(description["relations"] || %{}),
        kind in (spec["from"] || []),
        keys = get_in(fact, ["links", relation]) || [],
        keys != [],
        do: {String.capitalize(spec["label"] || relation), keys}
  end

  defp parent_kind(description, {:new, _kind, {relation, _parent}}),
    do: description |> get_in(["relations", relation, "to"]) |> List.wrap() |> List.first()

  defp missing(title, text, back),
    do: page(title, back, [Blocks.confirm(title: title, text: text, cancel_to: back)])

  defp unavailable(error, back),
    do:
      missing(
        "State did not answer",
        "#{error}. Showing nothing rather than something old.",
        back
      )

  @doc "The relations whose facts point at `kind`, with the keys pointing at this fact."
  def children(description, kind, answer) do
    for {relation, spec} <- Enum.sort(description["relations"] || %{}),
        kind in (spec["to"] || []) do
      label = get_in(spec, ["inverse", "label"]) || relation
      {String.capitalize(label), get_in(answer, ["incoming", relation]) || []}
    end
  end

  # Form inputs from the description

  # `only`: these properties, in this order. Otherwise every property a person may set.
  defp inputs(spec, values, opts \\ []) do
    properties =
      case opts[:only] do
        nil -> ordered(spec)
        names -> for name <- names, prop = spec["properties"][name], do: {name, prop}
      end

    for {name, prop} <- properties, settable?(prop) do
      Blocks.input(
        name: name,
        label: humanize(name),
        kind: input_kind(prop),
        value: values[name],
        required: prop["required"] == true,
        hint: prop["description"],
        choices: choices(prop)
      )
    end
  end

  defp input_kind(%{"values" => values}) when is_list(values), do: "choice"
  defp input_kind(%{"type" => "boolean"}), do: "boolean"
  # Text of several lines and sections, as the description marks it.
  defp input_kind(%{"multiline" => true}), do: "multiline"
  defp input_kind(_), do: "text"

  defp choices(%{"values" => values} = prop) when is_list(values) do
    none = if prop["required"], do: [], else: [Blocks.choice(value: "", label: "—")]
    none ++ Enum.map(values, &Blocks.choice(value: &1, label: get_in(prop, ["labels", &1]) || &1))
  end

  defp choices(%{"type" => "boolean"}),
    do: [Blocks.choice(value: "false", label: "no"), Blocks.choice(value: "true", label: "yes")]

  defp choices(_), do: nil

  @doc """
  How a fact of a kind is created, from the description (`create` in `rela/atlas.json`):
  `ask` (the fields a create form asks for), `id` (`prefix` plus the next free number,
  zero-padded to `digits`) and `defaults` (values for what it does not ask). Without a
  rule: every field a person may set, rela's id prefix, no defaults.
  """
  def create_rule(spec) do
    rule = spec["create"] || %{}
    prefix = List.first(spec["id_prefixes"] || List.wrap(spec["id_prefix"])) || ""

    %{
      ask: rule["ask"] || for({name, prop} <- ordered(spec), settable?(prop), do: name),
      prefix: get_in(rule, ["id", "prefix"]) || prefix,
      digits: get_in(rule, ["id", "digits"]) || 2,
      defaults: rule["defaults"] || %{}
    }
  end

  @doc """
  The next free key of a kind: the rule's prefix plus one more than the highest number
  among `keys` (and above `after`, when an earlier try was taken).
  """
  def next_key(spec, keys, after_number \\ 0) do
    %{prefix: prefix, digits: digits} = create_rule(spec)
    {:ok, pattern} = Regex.compile("^" <> Regex.escape(prefix) <> "(\\d+)$")

    highest =
      keys
      |> Enum.flat_map(fn key ->
        case Regex.run(pattern, key) do
          [_, n] -> [String.to_integer(n)]
          nil -> []
        end
      end)
      |> Enum.max(fn -> 0 end)

    number = max(highest, after_number) + 1
    {prefix <> String.pad_leading(Integer.to_string(number), digits, "0"), number}
  end

  @doc "The values of a new fact: what was asked, then the rule's defaults for the rest."
  def create_values(spec, raw) do
    asked = Map.take(raw, create_rule(spec).ask)
    Map.merge(create_rule(spec).defaults, values_for(spec, asked))
  end

  # A field a person may set; not one only a connector or the system fills.
  defp settable?(prop), do: not Map.has_key?(prop, "set_by")

  @doc """
  Turn a form's text values into the described types, for a fact. Unknown names are
  passed on so State can refuse them.
  """
  def values_for(spec, raw) do
    props = spec["properties"] || %{}

    for {name, text} <- raw, name != "_key", into: %{} do
      {name, typed(props[name], text)}
    end
  end

  defp typed(_prop, ""), do: ""
  defp typed(%{"type" => "boolean"}, "true"), do: true
  defp typed(%{"type" => "boolean"}, "false"), do: false

  defp typed(%{"type" => "integer"}, text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> text
    end
  end

  defp typed(_prop, text), do: text

  # Showing values

  # The primary property first, then choices, then flags, then the rest, so long text ends up last.
  defp ordered(spec) do
    primary = spec["primary"]

    (spec["properties"] || %{})
    |> Enum.sort_by(fn {name, prop} ->
      rank =
        cond do
          name == primary -> 0
          is_list(prop["values"]) -> 1
          prop["type"] == "boolean" -> 2
          true -> 3
        end

      {rank, name}
    end)
  end

  defp label(spec, fact), do: to_text(fact["values"][spec["primary"]]) |> blank(fact["key"])

  defp detail(spec, fact) do
    shown =
      for {name, prop} <- ordered(spec),
          name != spec["primary"],
          v = fact["values"][name],
          v not in [nil, "", false] do
        cond do
          is_list(prop["values"]) -> show(prop, v)
          prop["type"] == "boolean" -> humanize(name) |> String.downcase()
          true -> nil
        end
      end

    Enum.join([fact["key"] | Enum.reject(shown, &is_nil/1)], " · ")
  end

  defp show(%{"type" => "boolean"}, value), do: if(value in [true, "true"], do: "yes", else: "no")
  defp show(_prop, value) when value in [nil, ""], do: "—"
  defp show(%{"labels" => labels}, value) when is_map(labels), do: labels[value] || to_text(value)
  defp show(_prop, value), do: to_text(value)

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: to_string(value)

  defp blank("", fallback), do: fallback
  defp blank(value, _), do: value

  defp count(keys), do: Integer.to_string(length(keys))

  defp singular(spec, kind), do: spec["label"] || humanize(kind)
  defp plural(spec, kind), do: humanize(spec["plural"] || kind <> "s")

  defp humanize(name), do: name |> String.replace("_", " ") |> String.capitalize()

  defp first_line(nil), do: nil
  defp first_line(text), do: text |> String.split("\n") |> hd()
end
