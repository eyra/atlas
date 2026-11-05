defmodule AtlasTui.Interactions do
  @moduledoc """
  Console binding execution from the active BFF action blocks and legend ranges.
  Captured events retain projection, page, context and selected-row identity; an
  event is resolved again before execution, never replayed from a stored closure.
  """
  alias AtlasTui.{Blocks, Console, Model}
  alias AtlasBFFContract.Console, as: Contract

  def context(model) do
    cond do
      Model.step_form(model) ->
        "step_form"

      model.ask != nil ->
        "ask"

      model.plan != nil ->
        "plan_" <>
          if(model.plan.state in ["planning", "proposed", "running"],
            do: model.plan.state,
            else: "done"
          )

      Model.form(model) ->
        "form"

      Model.confirm(model) ->
        "confirm"

      true ->
        "browse"
    end
  end

  def install(model, page) do
    blocks = page["blocks"] || []
    markup = page["markup"] || []
    actions = Enum.filter(blocks, &(&1["type"] == "console_action"))
    groups = Enum.filter(markup, &(&1["kind"] == "legend"))
    ids = Enum.map(blocks, & &1["id"])

    valid =
      length(actions) <= 256 and Enum.all?(actions, &valid_action?(&1, page)) and
        valid_bindings?(actions) and
        length(Enum.uniq(Enum.map(actions, & &1["id"]))) == length(actions) and
        AtlasBFF.Markup.check(ids, markup) == :ok and
        Enum.all?(groups, fn group ->
          is_map(group["props"]) and group["props"]["context"] in Contract.contexts()
        end) and valid_groups?(actions, groups, ids)

    projection = if valid, do: %{actions: actions, groups: groups, ids: ids}, else: nil

    console = %{
      model.console
      | projection: projection,
        generation: model.console.generation + 1,
        action_error: if(valid, do: nil, else: "Unsupported or invalid Console actions")
    }

    content = Map.put(page, "blocks", Enum.reject(blocks, &(&1["type"] == "console_action")))
    # Auxiliary markup is consumed with its actions, never drawn as ordinary content.
    content = Map.put(content, "markup", Enum.reject(markup, &(&1["kind"] == "legend")))
    {%{model | console: console}, content}
  end

  def active(%{console: %{projection: nil}}), do: []

  def active(model) do
    projection = model.console.projection
    context = context(model)
    selected = selected_identity(model)
    {on, row_id} = if selected, do: {elem(selected, 0), elem(selected, 1)}, else: {nil, nil}

    scoped_ids =
      for group <- projection.groups,
          group["props"]["context"] == context,
          id <- range(projection.ids, group["start"], group["end"]),
          do: id

    Enum.filter(projection.actions, fn action ->
      scope = action["props"]["scope"]

      action["id"] in scoped_ids and
        (is_nil(scope["on"]) or scope["on"] in model.ids) and
        (is_nil(scope["row"]) or (scope["row"] == row_id and scope["on"] == on)) and
        scope["context"] == context
    end)
  end

  def capture(model, key) do
    token = token(key)
    matches = Enum.filter(active(model), &(token in &1["props"]["keys"]))

    case matches do
      [action] ->
        %{
          id: action["id"],
          generation: model.console.generation,
          context: context(model),
          focus: focus(model),
          path: model.path,
          selected: selected_identity(model)
        }

      _ ->
        nil
    end
  end

  def dispatch(model, nil), do: {model, []}

  def dispatch(model, event) do
    current =
      model.connected && model.console.phase == :ready && is_nil(model.console.expected) &&
        event.generation == model.console.generation && event.context == context(model) &&
        event.path == model.path && event.selected == selected_identity(model) &&
        event.focus == focus(model)

    action = if current, do: Enum.find(active(model), &(&1["id"] == event.id))

    if action && action["props"]["available"] == true do
      execute(model, action["props"]["operation"], action["props"]["label"])
    else
      {model, []}
    end
  end

  def key(model, key) do
    case capture(model, key) do
      nil -> Model.literal(model, key)
      event -> dispatch(model, event)
    end
  end

  defp execute(model, %{"name" => "tab_next"}, _label), do: Console.cycle(model, 1)
  defp execute(model, %{"name" => "tab_previous"}, _label), do: Console.cycle(model, -1)
  defp execute(model, %{"name" => "open", "to" => to}, _label), do: Console.navigate(model, to)

  defp execute(model, %{"name" => "open_url", "url" => url}, _label),
    do: Model.external(model, url)

  defp execute(model, %{"name" => "agent_ask"} = operation, label),
    do: Model.agent_action(model, label, operation["intent"])

  defp execute(model, %{"name" => name}, _label), do: Model.operation(model, name)

  defp selected_identity(model) do
    rows =
      Enum.flat_map(Enum.zip(model.ids, model.blocks), fn
        {id, %Blocks.List{rows: rows}} -> Enum.map(rows || [], &{id, &1.id, &1.to})
        _ -> []
      end)

    Enum.at(rows, model.selected)
  end

  defp valid_bindings?(actions) do
    revisions = Enum.map(actions, & &1["props"]["scope"]["revision"]) |> Enum.uniq()

    length(revisions) <= 1 and
      Enum.all?(Enum.with_index(actions), fn {left, index} ->
        Enum.all?(Enum.drop(actions, index + 1), fn right ->
          a = left["props"]
          b = right["props"]
          shared = Enum.any?(a["keys"], &(&1 in b["keys"]))

          overlap =
            a["scope"]["context"] == b["scope"]["context"] and
              Enum.all?(["on", "row"], fn key ->
                is_nil(a["scope"][key]) or is_nil(b["scope"][key]) or
                  a["scope"][key] == b["scope"][key]
              end)

          !(shared and overlap)
        end)
      end)
  end

  defp focus(model), do: {model.focus, model.part, model.steps.selected, model.steps.editing}

  defp range(ids, start, finish) do
    with from when is_integer(from) <- Enum.find_index(ids, &(&1 == start)),
         to when is_integer(to) <- Enum.find_index(ids, &(&1 == finish)),
         true <- from <= to do
      Enum.slice(ids, from..to)
    else
      _ -> []
    end
  end

  defp valid_action?(%{"id" => id, "props" => props} = action, page) when is_map(props) do
    scope = props["scope"]
    keys = props["keys"]
    reason = props["reason"]

    match?(%Blocks.ConsoleAction{}, Blocks.decode(action)) and
      text?(id, 128) and text?(props["label"], 256) and
      (is_nil(reason) or text?(reason, 512)) and
      is_list(keys) and length(keys) in 1..8 and Enum.all?(keys, &Contract.key?/1) and
      Contract.operation?(props["operation"]) and is_map(scope) and
      scope["page"] == page["path"] and text?(scope["revision"], 128) and
      scope["revision"] == page["actions_revision"] and
      scope["context"] in Contract.contexts() and valid_scope?(scope, page)
  end

  defp valid_action?(_, _), do: false

  defp valid_scope?(scope, page) do
    on = scope["on"]
    row = scope["row"]

    cond do
      row != nil ->
        text?(on, 128) and text?(row, 128) and
          Enum.any?(page["blocks"], fn block ->
            block["id"] == on and block["type"] == "list" and
              Enum.any?(block["props"]["rows"] || [], &(&1["id"] == row))
          end)

      on != nil ->
        text?(on, 128) and Enum.any?(page["blocks"], &(&1["id"] == on))

      true ->
        true
    end
  end

  defp valid_groups?(actions, groups, ids) do
    by_id = Map.new(actions, &{&1["id"], &1["props"]["scope"]["context"]})

    Enum.all?(groups, fn group ->
      covered = range(ids, group["start"], group["end"])
      covered != [] and Enum.all?(covered, &(Map.get(by_id, &1) == group["props"]["context"]))
    end) and
      Enum.all?(actions, fn action ->
        Enum.any?(groups, &(action["id"] in range(ids, &1["start"], &1["end"])))
      end)
  end

  defp text?(text, limit),
    do:
      is_binary(text) and byte_size(text) in 1..limit and String.valid?(text) and
        !String.match?(text, ~r/[\x00-\x1f\x7f]/)

  # Terminal decoding, independent of which operation the BFF assigns to a token.
  def token({:char, " "}), do: "Space"
  def token({:char, text}), do: text
  def token(:tab), do: "Tab"
  def token(:shift_tab), do: "Shift+Tab"
  def token(:enter), do: "Enter"
  def token(:esc), do: "Esc"
  def token(:up), do: "Up"
  def token(:down), do: "Down"
  def token(:left), do: "Left"
  def token(:right), do: "Right"
  def token(:home), do: "Home"
  def token(:end), do: "End"
  def token(:backspace), do: "Backspace"
  def token(:ctrl_c), do: "Ctrl+C"
  def token(:ctrl_s), do: "Ctrl+S"
  def token(:page_up), do: "PageUp"
  def token(:page_down), do: "PageDown"
  def token(_), do: nil
end
