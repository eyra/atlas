defmodule AtlasTui.Interactions do
  @moduledoc """
  Console binding execution from the active BFF action blocks and legend ranges.
  Captured events retain projection, page, context and selected-row identity; an
  event is resolved again before execution, never replayed from a stored closure.
  """
  alias AtlasTui.{Console, Model}

  @operations ~w(tab_next tab_previous list_next list_previous open_selected open back refresh quit scroll_up scroll_down focus_next focus_previous submit cancel)
  @contexts ~w(browse form confirm ask plan step-form legend)

  def context(model) do
    cond do
      Model.step_form(model) -> "step-form"
      model.ask != nil -> "ask"
      model.plan != nil -> "plan"
      Model.form(model) -> "form"
      Model.confirm(model) -> "confirm"
      true -> "browse"
    end
  end

  def install(model, page) do
    blocks = page["blocks"] || []
    markup = page["markup"] || []
    actions = Enum.filter(blocks, &(&1["type"] == "console_action"))
    groups = Enum.filter(markup, &(&1["kind"] == "legend"))
    ids = Enum.map(blocks, & &1["id"])

    valid =
      length(actions) <= 256 and Enum.all?(actions, &valid_action?/1) and
        length(Enum.uniq(Enum.map(actions, & &1["id"]))) == length(actions) and
        AtlasBFF.Markup.check(ids, markup) == :ok and
        Enum.all?(groups, fn group -> group["props"]["context"] in @contexts end)

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
    row = Enum.at(Model.rows(model), model.selected)
    row_id = row && row.id

    scoped_ids =
      for group <- projection.groups,
          group["props"]["context"] == context,
          id <- range(projection.ids, group["start"], group["end"]),
          do: id

    Enum.filter(projection.actions, fn action ->
      props = action["props"]

      action["id"] in scoped_ids and
        (is_nil(props["on"]) or props["on"] in model.ids) and
        (is_nil(props["row"]) or props["row"] == row_id)
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
      execute(model, action["props"]["operation"])
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

  defp execute(model, %{"name" => "tab_next"}), do: Console.cycle(model, 1)
  defp execute(model, %{"name" => "tab_previous"}), do: Console.cycle(model, -1)
  defp execute(model, %{"name" => "open", "to" => to}), do: Console.navigate(model, to)
  defp execute(model, %{"name" => name}), do: Model.operation(model, name)

  defp selected_identity(model) do
    row = Enum.at(Model.rows(model), model.selected)
    row && {row.id, row.to}
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

  defp valid_action?(%{"id" => id, "props" => props}) when is_map(props) do
    keys = props["keys"]
    operation = props["operation"]

    is_binary(id) and byte_size(id) in 1..128 and is_binary(props["label"]) and
      byte_size(props["label"]) in 1..256 and props["available"] in [true, false] and
      is_list(keys) and length(keys) in 1..8 and
      Enum.all?(keys, &(is_binary(&1) and byte_size(&1) in 1..32)) and
      is_map(operation) and operation["name"] in @operations
  end

  defp valid_action?(_), do: false

  # Terminal decoding, independent of which operation the BFF assigns to a token.
  def token({:char, text}), do: text
  def token(:tab), do: "Tab"
  def token(:shift_tab), do: "Shift+Tab"
  def token(:enter), do: "Enter"
  def token(:esc), do: "Esc"
  def token(:up), do: "Up"
  def token(:down), do: "Down"
  def token(:left), do: "Left"
  def token(:right), do: "Right"
  def token(:ctrl_s), do: "Ctrl+S"
  def token(:page_up), do: "PageUp"
  def token(:page_down), do: "PageDown"
  def token(_), do: nil
end
