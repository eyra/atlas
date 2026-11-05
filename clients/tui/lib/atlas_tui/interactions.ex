defmodule AtlasTui.Interactions do
  @moduledoc """
  Console operations from the current BFF projection. Contract owns validation,
  binding selection and action identity. The renderer adds local focus and shell
  revision checks to reject captured events after its own state changes.
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
    {projection, error} =
      case Contract.compile(page) do
        {:ok, projection} -> {projection, nil}
        {:error, _} -> {nil, "Unsupported or invalid Console actions"}
      end

    console = %{
      model.console
      | projection: projection,
        generation: model.console.generation + 1,
        action_error: error
    }

    names = Contract.presentation_names()

    content =
      page
      |> Map.put("blocks", Enum.reject(page["blocks"] || [], &(&1["type"] in names.blocks)))
      |> Map.put("markup", Enum.reject(page["markup"] || [], &(&1["kind"] in names.markup)))

    {%{model | console: console}, content}
  end

  def active(model) do
    case Contract.active(model.console.projection, current(model)) do
      {:ok, actions} -> actions
      _ -> []
    end
  end

  def capture(model, key) do
    case Contract.capture(model.console.projection, token(key), current(model)) do
      {:ok, event} ->
        Map.merge(event, %{focus: focus(model), shell_revision: shell_revision(model)})

      _ ->
        nil
    end
  end

  def dispatch(model, nil), do: {model, []}

  def dispatch(model, event) do
    valid =
      model.connected && model.console.phase == :ready && is_nil(model.console.expected) &&
        event[:focus] == focus(model) && event[:shell_revision] == shell_revision(model)

    resolved = if valid, do: Contract.resolve(model.console.projection, event, current(model))

    case resolved do
      {:ok, action} -> execute(model, action["props"]["operation"], action["props"]["label"])
      _ -> {model, []}
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

  defp current(model) do
    selected =
      Enum.flat_map(Enum.zip(model.ids, model.blocks), fn
        {id, %Blocks.List{rows: rows}} -> Enum.map(rows || [], &{id, &1.id || &1.to})
        _ -> []
      end)
      |> Enum.at(model.selected)

    {on, row} = selected || {nil, nil}

    %{
      path: model.path,
      context: context(model),
      generation: model.console.generation,
      on: on,
      row: row
    }
  end

  defp focus(model), do: {model.focus, model.part, model.steps.selected, model.steps.editing}
  defp shell_revision(%{console: %{shell: nil}}), do: nil
  defp shell_revision(model), do: model.console.shell["revision"]

  # Terminal decoding, independent of the operation the BFF assigns to each token.
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
