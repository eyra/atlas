defmodule AtlasTui.Model do
  @moduledoc """
  What the TUI shows and how keys change it. Pure: `message/2` takes what Control sent,
  `key/2` returns the new model and effects (`{:send, message}`, `:quit`).

  The TUI knows blocks only. Which keys open what comes from the blocks' actions and
  links; the TUI adds moving around, going back, refreshing and quitting. A link's key
  gives the effect `{:open_url, url}`, only for an http or https address.

  A page whose markup puts its blocks in columns (`parts/1`) has parts, each with its own
  room and scrolling. Tab moves the focus from part to part. In the part with the lists,
  the arrows move the selected row; in another, they scroll it. The rows of all lists on
  a page are one selection (`rows/1`).
  """

  alias AtlasTui.{Blocks, Text}
  alias AtlasTui.Blocks.{Columns, Confirm, Form, Input, Item}
  alias AtlasTui.Blocks.List, as: ListBlock

  @scroll_step 10

  defstruct env: nil,
            connected: false,
            path: nil,
            title: "",
            back: nil,
            blocks: [],
            # The view model's block ids, in order, and its markup (decoded entries).
            ids: [],
            markup: [],
            selected: 0,
            # A page longer than the screen: nil follows the selected row or the focus;
            # a number of lines is scrolled to by page up and page down.
            scroll: nil,
            # The part with the focus (nil: the one with the lists), and how far each part
            # is scrolled by hand (by part number; missing: its top, or its selected row).
            part: nil,
            scrolls: %{},
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
    {blocks, ids, markup} = Blocks.view_model(msg)
    same = msg["path"] == model.path
    updated = %{reason: msg["reason"], at: msg["at"], position: msg["position"]}

    model = %{
      model
      | path: msg["path"],
        title: msg["title"] || "",
        back: msg["back"],
        blocks: blocks,
        ids: ids,
        markup: markup,
        updated: updated,
        waiting: model.waiting and msg["reason"] not in ["stored", "refused"]
    }

    model = %{
      model
      | selected: keep_selection(model, same),
        focus: if(same, do: model.focus, else: 0),
        cursor: if(same, do: model.cursor, else: nil),
        scroll: if(same, do: model.scroll, else: first_scroll(blocks)),
        part: if(same, do: model.part, else: nil),
        scrolls: if(same, do: model.scrolls, else: %{})
    }

    model = if msg["reason"] == "hint", do: %{model | last_hint: updated}, else: model

    case form(model) do
      %Form{inputs: inputs} -> %{model | values: Map.new(inputs, &{&1.name, &1.value || ""})}
      nil -> %{model | values: %{}}
    end
  end

  def message(model, _other), do: model

  # A page about one fact opens at its top, even when a list under it has a selected row.
  defp first_scroll(blocks), do: if(Enum.any?(blocks, &match?(%Item{}, &1)), do: 0, else: nil)

  def disconnected(model), do: %{model | connected: false}

  # A list keeps the selected row when it is redrawn, even if rows moved.
  defp keep_selection(_model, false), do: 0

  defp keep_selection(model, true), do: min(model.selected, max(length(rows(model)) - 1, 0))

  # The block that takes the keys.

  def form(model), do: Enum.find(model.blocks, &match?(%Form{}, &1))
  def list(model), do: Enum.find(model.blocks, &match?(%ListBlock{}, &1))
  def confirm(model), do: Enum.find(model.blocks, &match?(%Confirm{}, &1))

  @doc "The rows of every list on the page, in order: one selection."
  def rows(model) do
    Enum.flat_map(model.blocks, fn
      %ListBlock{rows: rows} -> rows || []
      _ -> []
    end)
  end

  @doc """
  The parts of a page: the block ids of each column, when the page's markup puts all its
  blocks in columns of two or more. `[]` for a page in one part.
  """
  def parts(%__MODULE__{markup: []}), do: []

  def parts(model) do
    case AtlasSpec.Markup.tree(model.ids, model.markup) do
      [{:markup, %{"value" => %Columns{}}, [_, _ | _] = columns}] -> Enum.map(columns, &ids_in/1)
      _ -> []
    end
  end

  defp ids_in({:block, id}), do: [id]
  defp ids_in({:markup, _entry, children}), do: Enum.flat_map(children, &ids_in/1)

  @doc "The part with the focus: the one chosen with tab, else the first with a list."
  def part(model) do
    parts = parts(model)

    lists =
      for {id, %ListBlock{}} <- Enum.zip(model.ids, model.blocks), into: MapSet.new(), do: id

    cond do
      parts == [] -> nil
      model.part != nil -> rem(model.part, length(parts))
      true -> Enum.find_index(parts, fn ids -> Enum.any?(ids, &(&1 in lists)) end) || 0
    end
  end

  @doc "Whether the part with the focus holds the lists, so the arrows move the selection."
  def selecting?(model) do
    case part(model) do
      nil ->
        true

      part ->
        ids = Enum.at(parts(model), part)

        Enum.any?(Enum.zip(model.ids, model.blocks), fn {id, block} ->
          id in ids and match?(%ListBlock{}, block)
        end)
    end
  end

  def actions(model) do
    Enum.flat_map(model.blocks, fn
      %ListBlock{actions: actions} -> actions || []
      %Item{actions: actions} -> actions || []
      _ -> []
    end)
  end

  @doc "The web addresses the keys open: the item's, then the selected row's."
  def links(model) do
    selected = Enum.at(rows(model), model.selected)

    Enum.flat_map(model.blocks, fn
      %Item{links: links} -> links || []
      _ -> []
    end) ++ ((selected && selected.links) || [])
  end

  @doc "Whether the TUI opens `url`: only an http or https address with a host."
  def openable?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        not String.match?(url, ~r/[\s\x00-\x1f]/)

      _ ->
        false
    end
  end

  def openable?(_url), do: false

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
    rows = rows(model)
    part = part(model)
    action = Enum.find(actions(model), &(key == {:char, &1.key}))
    link = Enum.find(links(model), &(key == {:char, &1.key}))

    case key do
      _ when action != nil ->
        open(model, action.to)

      _ when link != nil ->
        open_url(model, link.url)

      # Tab moves the focus to the next part of a page in parts.
      k when k in [:tab, :shift_tab] and part != nil ->
        step = if k == :tab, do: 1, else: -1
        count = length(parts(model))
        {%{model | part: rem(part + step + count, count)}, []}

      # In a part without lists, the arrows scroll it, a line at a time.
      k when k in [:up, {:char, "k"}] and part != nil ->
        if selecting?(model),
          do:
            {%{
               model
               | selected: max(model.selected - 1, 0),
                 scrolls: Map.delete(model.scrolls, part)
             }, []},
          else: {scroll_part(model, part, -1), []}

      k when k in [:down, {:char, "j"}] and part != nil ->
        if selecting?(model),
          do:
            {%{
               model
               | selected: min(model.selected + 1, max(length(rows) - 1, 0)),
                 scrolls: Map.delete(model.scrolls, part)
             }, []},
          else: {scroll_part(model, part, 1), []}

      :page_down when part != nil ->
        {scroll_part(model, part, @scroll_step), []}

      :page_up when part != nil ->
        {scroll_part(model, part, -@scroll_step), []}

      # Moving in a list brings its selected row back in sight.
      k when k in [:up, {:char, "k"}] ->
        {%{model | selected: max(model.selected - 1, 0), scroll: nil}, []}

      k when k in [:down, {:char, "j"}] ->
        {%{model | selected: min(model.selected + 1, max(length(rows) - 1, 0)), scroll: nil}, []}

      :page_down ->
        {%{model | scroll: (model.scroll || 0) + @scroll_step}, []}

      :page_up ->
        {%{model | scroll: max((model.scroll || 0) - @scroll_step, 0)}, []}

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

  # How far a part is scrolled; the view keeps it within the part's lines.
  defp scroll_part(model, part, by),
    do: put_in(model.scrolls[part], max((model.scrolls[part] || 0) + by, 0))

  defp back(%{back: nil} = model), do: {model, []}
  defp back(model), do: open(model, model.back)

  defp open(model, nil), do: {model, []}
  defp open(model, to), do: {%{model | notice: nil}, [{:send, %{"op" => "open", "to" => to}}]}

  defp open_url(model, url) do
    if openable?(url),
      do:
        {%{model | notice: %{tone: "info", text: "Opened #{url} in the browser"}},
         [{:open_url, url}]},
      else:
        {%{model | notice: %{tone: "error", text: "Not opened: only http and https addresses"}},
         []}
  end

  defp submit(model, to, values),
    do: {%{model | waiting: true}, [{:send, %{"op" => "submit", "to" => to, "values" => values}}]}
end
