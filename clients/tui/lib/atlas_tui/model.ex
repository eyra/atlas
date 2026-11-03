defmodule AtlasTui.Model do
  @moduledoc """
  What the TUI shows and how keys change it. Pure: `message/2` takes what Control sent,
  `key/2` returns the new model and effects (`{:send, message}`, `:quit`).

  The TUI knows blocks only. Which keys open what comes from the blocks' actions; the
  TUI adds moving around, going back, refreshing and quitting.
  """

  alias AtlasTui.{Blocks, Text}
  alias AtlasTui.Blocks.{Confirm, Form, Input, Item}
  alias AtlasTui.Blocks.List, as: ListBlock

  defstruct env: nil,
            connected: false,
            path: nil,
            title: "",
            back: nil,
            blocks: [],
            selected: 0,
            focus: 0,
            # Where typing goes in a multi-line input: `{line, column}`, nil for the end.
            cursor: nil,
            values: %{},
            notice: nil,
            updated: nil,
            last_hint: nil,
            waiting: false,
            closed: false

  def new(env), do: %__MODULE__{env: env}

  # Messages from Control

  def message(model, %{"op" => "welcome"}), do: %{model | connected: true, notice: nil}

  def message(model, %{"op" => "bye", "text" => text}),
    do: %{model | notice: %{tone: "error", text: text}, closed: true}

  def message(model, %{"op" => "notice"} = msg) do
    notice = %{tone: msg["tone"], text: msg["text"], at: msg["at"]}
    %{model | notice: notice, waiting: msg["tone"] == "pending"}
  end

  def message(model, %{"op" => "page"} = msg) do
    blocks = Enum.map(msg["blocks"] || [], &Blocks.decode/1)
    same = msg["path"] == model.path
    updated = %{reason: msg["reason"], at: msg["at"], position: msg["position"]}

    model = %{
      model
      | path: msg["path"],
        title: msg["title"] || "",
        back: msg["back"],
        blocks: blocks,
        updated: updated,
        waiting: model.waiting and msg["reason"] not in ["stored", "refused"]
    }

    model = %{
      model
      | selected: keep_selection(model, same),
        focus: if(same, do: model.focus, else: 0),
        cursor: if(same, do: model.cursor, else: nil)
    }

    model = if msg["reason"] == "hint", do: %{model | last_hint: updated}, else: model

    case form(model) do
      %Form{inputs: inputs} -> %{model | values: Map.new(inputs, &{&1.name, &1.value || ""})}
      nil -> %{model | values: %{}}
    end
  end

  def message(model, _other), do: model

  def disconnected(model), do: %{model | connected: false}

  # A list keeps the selected row when it is redrawn, even if rows moved.
  defp keep_selection(_model, false), do: 0

  defp keep_selection(model, true) do
    case list(model) do
      %ListBlock{rows: rows} -> min(model.selected, max(length(rows) - 1, 0))
      nil -> 0
    end
  end

  # The block that takes the keys.

  def form(model), do: Enum.find(model.blocks, &match?(%Form{}, &1))
  def list(model), do: Enum.find(model.blocks, &match?(%ListBlock{}, &1))
  def confirm(model), do: Enum.find(model.blocks, &match?(%Confirm{}, &1))

  def actions(model) do
    Enum.flat_map(model.blocks, fn
      %ListBlock{actions: actions} -> actions || []
      %Item{actions: actions} -> actions || []
      _ -> []
    end)
  end

  @doc "What can take focus in a form: its inputs (not the read-only ones), then the buttons."
  def focusable(%Form{inputs: inputs}),
    do: Enum.reject(inputs, &(&1.kind == "readonly")) ++ [:submit, :cancel]

  # Keys

  def key(model, :ctrl_c), do: {model, [:quit]}
  def key(%{closed: true} = model, _key), do: {model, [:quit]}

  def key(model, key) do
    cond do
      form = form(model) -> form_key(model, form, key)
      confirm = confirm(model) -> confirm_key(model, confirm, key)
      true -> browse_key(model, key)
    end
  end

  defp browse_key(model, key) do
    rows = (list(model) && list(model).rows) || []
    action = Enum.find(actions(model), &(key == {:char, &1.key}))

    case key do
      _ when action != nil ->
        open(model, action.to)

      k when k in [:up, {:char, "k"}] ->
        {%{model | selected: max(model.selected - 1, 0)}, []}

      k when k in [:down, {:char, "j"}] ->
        {%{model | selected: min(model.selected + 1, max(length(rows) - 1, 0))}, []}

      k when k in [:enter, :right] and rows != [] ->
        open(model, Enum.at(rows, model.selected).to)

      k when k in [:esc, :left, {:char, "b"}] ->
        back(model)

      {:char, "r"} ->
        {model, [{:send, %{"op" => "refresh"}}]}

      {:char, "q"} ->
        {model, [:quit]}

      _ ->
        {model, []}
    end
  end

  defp confirm_key(model, %Confirm{} = confirm, key) do
    case key do
      k when k in [{:char, "y"}, :enter] and confirm.confirm_to != nil ->
        submit(model, confirm.confirm_to, %{})

      k when k in [{:char, "n"}, :esc, :left, {:char, "b"}, :enter] ->
        open(model, confirm.cancel_to)

      {:char, "q"} ->
        {model, [:quit]}

      _ ->
        {model, []}
    end
  end

  defp form_key(model, %Form{} = form, key) do
    items = focusable(form)
    focus = min(model.focus, length(items) - 1)
    current = Enum.at(items, focus)

    case {key, current} do
      {:ctrl_s, _} ->
        submit(model, form.submit_to, model.values)

      {:esc, _} ->
        open(model, form.cancel_to || model.back)

      # Text of several lines: enter starts a new line, the arrows move in the text, and
      # leave it past its first or last line; tab always goes on.
      {k, %Input{kind: "multiline", name: name}} when k not in [:tab, :shift_tab] ->
        case Text.key(model.values[name] || "", model.cursor, k) do
          {:ok, text, cursor} -> {%{put_in(model.values[name], text) | cursor: cursor}, []}
          {:leave, :up} -> {focus_to(model, focus - 1), []}
          {:leave, :down} -> {focus_to(model, focus + 1), []}
          :ignore -> {model, []}
        end

      {k, _} when k in [:up, :shift_tab] ->
        {focus_to(model, focus - 1), []}

      {k, _} when k in [:down, :tab] ->
        {focus_to(model, focus + 1), []}

      {:enter, :submit} ->
        submit(model, form.submit_to, model.values)

      {:enter, :cancel} ->
        open(model, form.cancel_to || model.back)

      {:enter, %Input{}} ->
        {focus_to(model, focus + 1), []}

      {k, :submit} when k in [:left, :right] ->
        {focus_to(model, focus + 1), []}

      {k, :cancel} when k in [:left, :right] ->
        {focus_to(model, focus - 1), []}

      {k, %Input{kind: kind} = input} when kind in ["choice", "boolean"] ->
        choose(model, input, k)

      {{:char, c}, %Input{} = input} ->
        edit(model, input, &(&1 <> c))

      {:backspace, %Input{} = input} ->
        edit(model, input, &String.slice(&1, 0..-2//1))

      _ ->
        {model, []}
    end
  end

  # Moving down into a multi-line input starts at its beginning; moving up, at its end.
  defp focus_to(model, to) do
    last = length(focusable(form(model))) - 1
    to = to |> max(0) |> min(last)

    cond do
      to > model.focus -> %{model | focus: to, cursor: {0, 0}}
      to < model.focus -> %{model | focus: to, cursor: nil}
      true -> model
    end
  end

  defp choose(model, %Input{choices: choices, name: name}, key) do
    values = Enum.map(choices || [], & &1.value)
    at = Enum.find_index(values, &(&1 == model.values[name])) || 0

    step =
      case key do
        :left -> -1
        k when k in [:right, {:char, " "}] -> 1
        _ -> 0
      end

    if values == [] or step == 0 do
      {model, []}
    else
      value = Enum.at(values, rem(at + step + length(values), length(values)))
      {put_in(model.values[name], value), []}
    end
  end

  defp edit(model, %Input{kind: "text", name: name}, fun),
    do: {put_in(model.values[name], fun.(model.values[name] || "")), []}

  defp edit(model, _input, _fun), do: {model, []}

  defp back(%{back: nil} = model), do: {model, []}
  defp back(model), do: open(model, model.back)

  defp open(model, nil), do: {model, []}
  defp open(model, to), do: {%{model | notice: nil}, [{:send, %{"op" => "open", "to" => to}}]}

  defp submit(model, to, values),
    do: {%{model | waiting: true}, [{:send, %{"op" => "submit", "to" => to, "values" => values}}]}
end
