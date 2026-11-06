defmodule AtlasTui.View do
  @moduledoc """
  Draws the model as lines for a terminal of `width` × `height`. Pure, so tests can read
  the screen. Each line is a list of `{style, text}` segments; `to_ansi/1` adds colour.
  """

  alias AtlasTui.Blocks.{
    Confirm,
    Fallback,
    Form,
    Highlight,
    Input,
    Item,
    Part,
    Plan,
    Section
  }

  alias AtlasTui.Blocks.List, as: ListBlock
  alias AtlasTui.{Model, Text}

  @label_width 16
  # A multi-line input that does not have the focus shows at most this many rows.
  @resting_rows 8
  # A focused one never shows fewer than this, however small the screen.
  @least_rows 3
  # Markup says what a stretch of a page means; how it looks is this view's choice. A page
  # in parts shows them side by side from this width; narrower, one above the other.
  @side_by_side 120

  @doc """
  The contract's names this view knows: the blocks it draws, and the kinds of markup it
  draws or, for now, passes through. A test fails when the contract has one it does not.
  """
  def known,
    do: %{
      blocks: ~w(list item form confirm plan console_action),
      markup: ~w(part section highlight legend)
    }

  @doc "The screen: exactly `height` lines of plain segments."
  def render(%Model{} = model, width, height, reconcile_seconds) do
    width = max(width, 1)
    height = max(height, 1)
    # What waits for the user, on every page: Control's words for it.
    count = if model.count, do: " · " <> model.count, else: ""

    header = [
      [
        {env_style(model.env), " Atlas · #{model.env}"},
        {:pending, count},
        {:dim,
         pad_left(
           model.title <> " ",
           width - 13 - String.length(model.env) - String.length(count)
         )}
      ],
      [{:dim, String.duplicate("─", width)}]
    ]

    header = if model.console, do: AtlasTui.ConsoleView.header(model, width), else: header

    # The footer: help (on more lines when it does not fit on one), a rule, the notice and
    # the status line. A page longer than its room adds scrolling to the help.
    room_for = fn help ->
      max(height - length(header) - 3 - length(footer_help(model, help)), 1)
    end

    short = help_lines(help(model, false), width)
    {lines, long} = laid_out(model, width, room_for.(short))
    help = help_lines(help(model, long), width)
    room = room_for.(help)

    {lines, _} =
      if room == room_for.(short), do: {lines, long}, else: laid_out(model, width, room)

    body = window(lines, model, room)
    body = body ++ Elixir.List.duplicate([], room - length(body))

    footer =
      footer_help(model, help) ++
        [
          [{:dim, String.duplicate("─", width)}],
          console_notice(model),
          status(model, reconcile_seconds)
        ]

    Enum.map(Enum.take(header ++ body ++ footer, height), &fit(&1, width))
  end

  @doc "The screen as plain text, for tests and evidence."
  def plain(lines),
    do:
      Enum.map_join(lines, "\n", fn line ->
        line |> Enum.map_join(&elem(&1, 1)) |> String.trim_trailing()
      end)

  @doc "The screen as ANSI, ready to write from the top-left corner."
  def to_ansi(lines, theme \\ :legacy)

  def to_ansi(lines, :legacy) do
    rows = Enum.map(lines, fn line -> [Enum.map(line, &segment/1), "\e[0m\e[K"] end)
    ["\e[H", Enum.intersperse(rows, "\r\n"), "\e[J"]
  end

  def to_ansi(lines, theme) do
    base = AtlasTui.Palette.ansi(:plain, theme)

    rows =
      Enum.map(lines, fn line ->
        [
          base,
          Enum.map(line, fn {style, text} -> [AtlasTui.Palette.ansi(style, theme), text] end),
          base,
          "\e[K"
        ]
      end)

    ["\e[H", Enum.intersperse(rows, "\r\n"), base, "\e[J"]
  end

  # Prod stands out (white on red), so Melle never takes one environment for the other.
  defp env_style("prod"), do: :prod
  defp env_style(_env), do: :bold

  defp segment({:plain, text}), do: ["\e[0m", text]
  defp segment({:prod, text}), do: ["\e[0;1;97;41m", text]
  defp segment({:bold, text}), do: ["\e[0;1m", text]
  defp segment({:dim, text}), do: ["\e[0;2m", text]
  defp segment({:border, text}), do: ["\e[0;2m", text]
  defp segment({:selected, text}), do: ["\e[0;7m", text]
  defp segment({:cursor, text}), do: ["\e[0;7m", text]
  defp segment({:ok, text}), do: ["\e[0;32m", text]
  defp segment({:error, text}), do: ["\e[0;31m", text]
  defp segment({:pending, text}), do: ["\e[0;33m", text]
  defp segment({:info, text}), do: ["\e[0;36m", text]

  # Body

  defp body(%Model{console: %{legend: legend}} = model, width, room) when legend != nil,
    do: AtlasTui.LegendView.render(model, width, room)

  defp body(%Model{connected: false, closed: false}, _width, _room) do
    [
      [],
      [{:error, " Not connected to Control. Retrying…"}],
      [{:dim, " Nothing old is shown as if it were current."}]
    ]
  end

  # The agent's plan shows over the page; the page stays underneath and follows hints.
  defp body(%Model{plan: %Plan{}} = model, width, room) do
    block = Model.step_form(model) || %{model.plan | steps: Model.plan_steps(model)}
    block(block, 0, model, width, room)
  end

  defp body(%Model{blocks: []}, _width, _room), do: [[], [{:dim, " Waiting for Control…"}]]

  defp body(model, width, room), do: nodes(content(model), model, width, room)

  # The body's lines, and whether it is longer than its room. A page in parts fills its
  # room exactly, each part scrolled on its own; a part that is cut says so itself.
  defp laid_out(model, width, room) do
    if model.connected and model.blocks != [] and model.plan == nil and
         !(model.console && model.console.legend) and
         Model.parts(model) != [],
       do: parts(content(model), model, width, room),
       else: plain_layout(model, width, room)
  end

  defp plain_layout(model, width, room) do
    lines = body(model, width, room)
    {lines, length(lines) > room}
  end

  # The view model as a tree, top down: blocks (with where their rows start in the page's
  # one selection), and markup around them.
  defp content(%Model{markup: []} = model),
    do: Enum.map(with_offsets(model), fn {_id, block, at} -> {:block, block, at} end)

  defp content(model) do
    by_id = Map.new(with_offsets(model), fn {id, block, at} -> {id, {block, at}} end)

    model.ids
    |> AtlasBFF.Markup.tree(model.markup)
    |> blocks_in(by_id)
  end

  defp with_offsets(model) do
    {placed, _} =
      model.ids
      |> Enum.zip(model.blocks)
      |> Enum.map_reduce(0, fn
        {id, %ListBlock{rows: rows} = block}, at -> {{id, block, at}, at + length(rows || [])}
        {id, block}, at -> {{id, block, at}, at}
      end)

    placed
  end

  defp blocks_in(tree, by_id) do
    Enum.map(tree, fn
      {:block, id} ->
        {block, at} = Map.fetch!(by_id, id)
        {:block, block, at}

      {:markup, entry, children} ->
        {:markup, entry, blocks_in(children, by_id)}
    end)
  end

  # A page in parts: side by side when the terminal is wide enough (the first part the
  # wider), else one above the other, each given the room it needs as far as there is
  # room. Each part scrolls on its own; the one with the focus has a bright frame.
  defp parts(parts, model, width, room) do
    focus = Model.part(model)

    drawn =
      parts
      |> Enum.with_index()
      |> Enum.map(fn {node, i} -> {i, node} end)

    if width >= @side_by_side do
      first = div(width * 3, 5)
      widths = [first | List.duplicate(width - first, length(parts) - 1)]

      columns =
        for {{i, node}, w} <- Enum.zip(drawn, widths),
            do: {part(node, model, i == focus, model.scrolls[i], w, room), w}

      lines =
        for row <- 0..(room - 1) do
          Enum.flat_map(columns, fn {{lines, _cut}, w} ->
            line = Enum.at(lines, row) || []
            pad_line(fit(line, w), w)
          end)
        end

      {lines, Enum.any?(columns, fn {{_, cut}, _} -> cut end)}
    else
      needs = for {_i, node} <- drawn, do: length(part_lines(node, model, width)) + 2
      heights = share(needs, room, todo_part(parts) || related_part(parts) || lists_part(model))

      drawn =
        for {{i, node}, h} <- Enum.zip(drawn, heights),
            do: part(node, model, i == focus, model.scrolls[i], width, h)

      lines = Enum.flat_map(drawn, &elem(&1, 0))
      {Enum.take(lines, room), Enum.any?(drawn, &elem(&1, 1))}
    end
  end

  # Room for parts one above the other: each its need when all fit. Else the part with
  # the lists first, so long content never pushes them away, while every other part keeps
  # a third of the room (or what it needs, when less); the rest is shared equally.
  defp share(needs, room, first) do
    cond do
      Enum.sum(needs) <= room ->
        needs

      first == nil ->
        equal(needs, room, List.duplicate(0, length(needs)))

      true ->
        others = List.delete_at(needs, first)
        kept = others |> Enum.map(&min(&1, max(div(room, 3), 5))) |> Enum.sum()
        need = Enum.at(needs, first)
        top = need |> min(room - kept) |> max(min(need, 3))
        given = equal(others, room - top, List.duplicate(0, length(others)))
        List.insert_at(given, first, top)
    end
  end

  defp equal(needs, room, given) do
    open = for {need, i} <- Enum.with_index(needs), Enum.at(given, i) < need, do: i
    left = room - Enum.sum(given)

    if open == [] or left <= 0 do
      given
    else
      each = max(div(left, length(open)), 1)

      given =
        Enum.reduce(open, given, fn i, given ->
          left = room - Enum.sum(given)
          add = Enum.min([each, Enum.at(needs, i) - Enum.at(given, i), left])
          List.update_at(given, i, &(&1 + max(add, 0)))
        end)

      if room - Enum.sum(given) == left, do: given, else: equal(needs, room, given)
    end
  end

  # The owner's part (what to do, IS-Atlas-54), if any: given room first, before the lists.
  defp todo_part(parts),
    do: Enum.find_index(parts, &match?({:markup, %{"value" => %Part{role: "todo"}}, _}, &1))

  # The part whose role is related (what the page links to), if any: given room first.
  defp related_part(parts) do
    Enum.find_index(parts, &match?({:markup, %{"value" => %Part{role: "related"}}, _}, &1))
  end

  # The part that holds the page's lists, if any.
  defp lists_part(model) do
    lists = for {id, %ListBlock{}} <- Enum.zip(model.ids, model.blocks), do: id
    Enum.find_index(Model.parts(model), fn ids -> Enum.any?(ids, &(&1 in lists)) end)
  end

  # What a part holds, at the width inside its frame.
  defp part_lines({:markup, %{"value" => %Part{}}, children}, model, width),
    do: nodes(children, model, width - 4, :all)

  defp part_lines(node, model, width), do: nodes([node], model, width, :all)

  # One part, `height` lines: its frame and title, and its lines from where it is
  # scrolled to (by hand, or to keep its selected row in sight). When it holds more than
  # fits, its last line says how much more there is.
  defp part(node, model, focused, scrolled, width, height) do
    title =
      case node do
        {:markup, %{"value" => %Part{title: title}}, _} -> title
        _ -> nil
      end

    inner = width - 4
    lines = part_lines(node, model, width)
    room = max(height - 2, 1)
    total = length(lines)
    cut = total > room
    shown = if cut, do: room - 1, else: room
    last = max(total - shown, 0)
    selected = Enum.find_index(lines, &selected_line?/1)

    start =
      cond do
        not cut -> 0
        scrolled != nil -> min(scrolled, last)
        selected != nil -> (selected - div(shown, 2)) |> min(last) |> max(0)
        true -> 0
      end

    visible = Enum.slice(lines, start, shown)
    below = total - start - length(visible)

    more =
      [
        start > 0 && "↑ #{count(start, "line")} above",
        below > 0 && "… #{count(below, "more line")}"
      ]
      |> Enum.filter(& &1)

    body =
      visible ++
        if(cut, do: [[{:dim, "   " <> Enum.join(more, " · ")}]], else: []) ++
        List.duplicate([], max(room - length(visible) - if(cut, do: 1, else: 0), 0))

    style = if focused, do: :bold, else: :dim
    label = if title, do: "─ " <> title <> " ", else: ""
    top = " ┌" <> label <> String.duplicate("─", max(inner - String.length(label), 0)) <> "┐"

    framed =
      for line <- body do
        line = fit(line, inner)
        [{style, " │"} | pad_line(line, inner)] ++ [{style, "│"}]
      end

    lines =
      ([[{style, top}]] ++ framed ++ [[{style, " └" <> String.duplicate("─", inner) <> "┘"}]])
      |> Enum.take(height)

    {lines, cut}
  end

  defp count(n, noun), do: "#{n} #{noun}#{if n == 1, do: "", else: "s"}"

  defp pad_line(line, width) do
    used = line |> Enum.map(&String.length(elem(&1, 1))) |> Enum.sum()
    line ++ [{:plain, String.duplicate(" ", max(width - used, 0))}]
  end

  defp nodes(tree, model, width, room) do
    tree
    |> Enum.map(fn
      {:block, block, at} -> block(block, at, model, width, room)
      {:markup, %{"value" => value}, children} -> markup(value, children, model, width, room)
    end)
    |> Enum.intersperse([[]])
    |> Enum.concat()
  end

  # Markup this TUI draws: a part as a box with its title, a section as a heading. It does
  # not draw highlights yet; their blocks show as they are.
  defp markup(%Section{title: title}, children, model, width, room) do
    rule = String.duplicate("─", max(width - String.length(title) - 3, 0))
    [[{:bold, " " <> title}, {:dim, " " <> rule}], []] ++ nodes(children, model, width, room)
  end

  defp markup(%Part{title: title}, children, model, width, room) do
    inner = width - 4
    label = if title, do: "─ " <> title <> " ", else: ""
    top = " ┌" <> label <> String.duplicate("─", max(inner - String.length(label), 0)) <> "┐"

    lines =
      for line <- nodes(children, model, inner, room) do
        line = fit(line, inner)
        used = line |> Enum.map(&String.length(elem(&1, 1))) |> Enum.sum()
        [{:dim, " │"} | line] ++ [{:plain, String.duplicate(" ", inner - used)}, {:dim, "│"}]
      end

    [[{:dim, top}]] ++ lines ++ [[{:dim, " └" <> String.duplicate("─", inner) <> "┘"}]]
  end

  defp markup(%Highlight{}, children, model, width, room),
    do: nodes(children, model, width, room)

  # Rows in columns: the id (as wide as the list's longest), the label (the rest, cut
  # with "…" only when it must be) and the detail (at most a third of the width).
  defp block(%ListBlock{} = list, at, %{console: console} = model, width, _room)
       when console != nil do
    rows = list.rows || []
    inner = max(width - 4, 1)

    heading =
      if list.title,
        do: [
          [{:bold, " " <> list.title}, {:dim, " · #{length(rows)}"}],
          [{:border, " " <> String.duplicate("─", max(width - 2, 0))}]
        ],
        else: []

    content =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, i} ->
        selected = at + i == model.selected
        style = if selected, do: :selected, else: :bold
        marker = if selected, do: " › ", else: "   "
        id = if row.id in [nil, ""], do: "", else: cut(row.id, max(div(inner, 3), 1)) <> "  "
        prefix = marker <> id
        stacked = String.length(prefix) >= width
        label_prefix = if stacked, do: "", else: prefix
        label_room = max(width - String.length(label_prefix), 1)
        labels = list_wrap(row.label || "", label_room)

        title =
          labels
          |> Enum.with_index()
          |> Enum.map(fn {line, n} ->
            prefix =
              if n == 0,
                do: label_prefix,
                else: String.duplicate(" ", String.length(label_prefix))

            [{style, prefix <> line}]
          end)

        indent = String.duplicate(" ", min(3, max(width - 1, 0)))

        detail =
          for line <- list_wrap(row.detail || "", width - String.length(indent)),
              line != "",
              do: [{:dim, indent <> line}]

        identity = if stacked, do: Enum.map(list_wrap(prefix, width), &[{style, &1}]), else: []
        identity ++ title ++ detail
      end)

    indent = String.duplicate(" ", min(3, max(width - 1, 0)))

    empty =
      for line <- list_wrap(list.empty || "Nothing here.", width - String.length(indent)),
          do: [{:dim, indent <> line}]

    separator = [[{:border, " " <> String.duplicate("─", max(width - 2, 0))}]]

    heading ++
      if(rows == [], do: empty, else: content |> Enum.intersperse(separator) |> Enum.concat())
  end

  defp block(%ListBlock{} = list, at, model, width, _room) do
    rows = list.rows || []
    id_width = rows |> Enum.map(&String.length(&1.id || "")) |> Enum.max(fn -> 0 end)
    id_column = if id_width > 0, do: id_width + 2, else: 0
    detail = rows |> Enum.map(&String.length(&1.detail || "")) |> Enum.max(fn -> 0 end)
    detail_column = if detail > 0, do: min(detail, div(width, 3)) + 2, else: 0
    label_width = max(width - 4 - id_column - detail_column, 12)

    rows =
      case list.rows do
        [] ->
          # What fills an empty list may take more than a line: it wraps.
          for line <- Text.wrap(list.empty || "Nothing here.", width - 4),
              do: [{:dim, "   " <> line}]

        rows ->
          rows
          |> Enum.with_index()
          |> Enum.flat_map(fn {row, i} ->
            selected = at + i == model.selected
            style = if selected, do: :selected, else: :plain
            marker = if selected, do: " › ", else: "   "

            id = if id_column > 0, do: pad(row.id || "", id_width) <> "  ", else: ""
            label = {style, marker <> id <> pad(cut(row.label, label_width), label_width)}
            dim = if selected, do: :selected, else: :dim

            # A detail longer than its column (why a fact is yours, say) goes under the
            # label, whole, rather than cut at the edge.
            if row.detail && String.length(row.detail) > detail_column - 2 do
              indent = String.duplicate(" ", 3 + id_column)

              [
                [label]
                | for(
                    line <- Text.wrap(row.detail, width - 4 - id_column),
                    do: [{:dim, indent <> line}]
                  )
              ]
              |> List.update_at(0, &(&1 ++ [{dim, ""}]))
            else
              [[label, {dim, if(row.detail, do: "  " <> row.detail, else: "")}]]
            end
          end)
      end

    # A list in a section leaves its title to the section.
    if list.title, do: [[{:bold, " " <> list.title}], []] ++ rows, else: rows
  end

  # Values keep their line breaks and blank lines; a heading line (`#`) is bold.
  defp block(%Item{} = item, _at, _model, width, _room) do
    fields =
      Enum.flat_map(item.fields, fn pair ->
        [first | rest] = Text.wrap(pair.value || "—", width - @label_width - 4)

        indent = String.duplicate(" ", @label_width + 3)

        # The fact that set it: since when, by whom, why (a link's origin).
        origin =
          for line <- Text.wrap(origin_text(pair.origin), width - @label_width - 4),
              line != "",
              do: [{:plain, indent}, {:dim, line}]

        [
          [{:dim, "   " <> pad(pair.label, @label_width)}, text_row(first)]
          | Enum.map(rest, &[{:plain, indent}, text_row(&1)]) ++ origin
        ]
      end)

    title(item.title, width) ++ [[]] ++ fields
  end

  # A form that does not fit gives its focused multi-line input fewer rows, down to a few.
  defp block(%Form{} = form, _at, model, width, room) do
    lines = form_lines(form, model, width, :all)
    over = length(lines) - room

    case focused_rows(form, model, width) do
      rows when over > 0 and rows > @least_rows ->
        form_lines(form, model, width, max(rows - over, @least_rows))

      _ ->
        lines
    end
  end

  defp block(%Confirm{} = confirm, _at, _model, width, _room) do
    choices =
      if confirm.confirm_to,
        do: [
          [
            {:plain, "   "},
            {:error, "[y] #{confirm.confirm_label || "Yes"}"},
            {:plain, "   [n] Cancel"}
          ]
        ],
        else: [[{:plain, "   [enter] Back"}]]

    title(confirm.title, width) ++
      [[]] ++
      Enum.map(Text.wrap(confirm.text, width - 4), &[{:plain, "   " <> &1}]) ++ [[]] ++ choices
  end

  # An agent's plan: what was asked, what it says, and each step with the values of the
  # form it fills. The selected step is the one space, e and the arrows act on.
  defp block(%Plan{} = plan, _at, model, width, _room) do
    about =
      [
        {"You asked", plan.request},
        {"Before", plan.before},
        {"By", plan.by},
        {"It says", plan.summary}
      ]
      |> Enum.reject(fn {_, value} -> value in [nil, ""] end)
      |> Enum.flat_map(fn {label, value} ->
        [first | rest] = Text.wrap(value, width - @label_width - 4)

        [
          [{:dim, "   " <> pad(label, @label_width)}, {:plain, first}]
          | Enum.map(rest, &[{:plain, String.duplicate(" ", @label_width + 3) <> &1}])
        ]
      end)

    steps =
      plan.steps
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, i} ->
        selected = plan.state == "proposed" and i == model.steps.selected
        step_lines(step, selected, width)
      end)

    title(plan.title, width) ++ [[]] ++ about ++ [[]] ++ steps
  end

  defp block(%Fallback{type: type}, _at, _model, _width, _room),
    do: [[{:dim, "   (a #{type || "?"} block this TUI cannot show)"}]]

  # List prefixes and part frames can leave fewer than ten columns. Use the
  # actual budget; Text.wrap's reading/editor defaults remain unchanged.
  defp list_wrap(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      for {start, length} <- Text.rows(line, max(width, 1)),
          do: line |> String.slice(start, length) |> String.trim_trailing()
    end)
  end

  @step_marks %{
    "proposed" => {:ok, "[✓]"},
    "dropped" => {:dim, "[ ]"},
    "blocked" => {:error, "[!]"},
    "running" => {:pending, "[…]"},
    "stored" => {:ok, "[✓]"},
    "refused" => {:error, "[✗]"},
    "not_run" => {:dim, "[-]"}
  }

  # A step: its mark and the form's title, its values, why, and what became of it.
  defp step_lines(step, selected, width) do
    {tone, mark} = @step_marks[step.state] || {:dim, "[?]"}
    dim = step.state in ["dropped", "not_run"]
    head_style = if selected, do: :selected, else: if(dim, do: :dim, else: :bold)
    marker = if selected, do: " › ", else: "   "

    head = [
      {head_style, marker},
      {if(selected, do: :selected, else: tone), mark},
      {head_style, " #{step.n}. #{step.label}"}
    ]

    values =
      for input <- step.inputs || [],
          row <- value_rows(input, width) do
        row
      end

    why =
      if step.why,
        do: Enum.map(Text.wrap("why: " <> step.why, width - 9), &[{:dim, "       " <> &1}]),
        else: []

    detail =
      case step.detail do
        nil ->
          []

        text ->
          style =
            %{"blocked" => :error, "refused" => :error, "not_run" => :dim}[step.state] || :ok

          Enum.map(Text.wrap(text, width - 9), &[{style, "       " <> &1}])
      end

    [head] ++ values ++ why ++ detail ++ [[]]
  end

  # A value of a step, at most a few rows; the rest is one edit (e) away.
  @value_rows 3
  defp value_rows(input, width) do
    label = "       " <> pad(input.label, @label_width - 3) <> " "
    rows = Text.wrap(input.value || "—", width - String.length(label) - 2)
    shown = Enum.take(rows, @value_rows)

    shown =
      if length(rows) > @value_rows, do: List.update_at(shown, -1, &(&1 <> " …")), else: shown

    indent = String.duplicate(" ", String.length(label))

    shown
    |> Enum.with_index()
    |> Enum.map(fn
      {row, 0} -> [{:dim, label}, {:plain, row}]
      {row, _} -> [{:plain, indent <> row}]
    end)
  end

  defp title(text, width), do: Enum.map(Text.wrap(text, width - 2), &[{:bold, " " <> &1}])

  defp text_row("#" <> _ = row), do: {:bold, row}
  defp text_row(row), do: {:plain, row}

  defp form_lines(%Form{} = form, model, width, rows) do
    items = Model.focusable(form)
    focus = min(model.focus, length(items) - 1)

    errors =
      Enum.flat_map(form.errors || [], fn error ->
        [first | rest] = Text.wrap(error, width - 7)
        [[{:error, "   ! " <> first}] | Enum.map(rest, &[{:error, "     " <> &1}])]
      end)

    inputs =
      Enum.flat_map(form.inputs, fn input ->
        focused = Enum.at(items, focus) == input
        value = model.values[input.name] || ""

        input_lines(
          input,
          value,
          if(focused, do: model.cursor),
          focused,
          field_width(width),
          rows
        )
      end)

    buttons = [
      [
        {:plain, "   "},
        {if(Enum.at(items, focus) == :submit, do: :selected, else: :bold),
         "[ #{form.submit_label} ]"},
        {:plain, "  "},
        {if(Enum.at(items, focus) == :cancel, do: :selected, else: :plain), "[ Cancel ]"}
      ]
    ]

    hint =
      case Enum.at(items, focus) do
        %Input{hint: hint} when is_binary(hint) ->
          Enum.map(Text.wrap(hint, width - 6), &[{:dim, "   " <> &1}])

        _ ->
          []
      end

    title(form.title, width) ++
      [[]] ++
      errors ++ if(errors == [], do: [], else: [[]]) ++ inputs ++ [[]] ++ buttons ++ [[]] ++ hint
  end

  # The width inside a text field's brackets.
  defp field_width(width), do: max(width - @label_width - 6, 12)

  # How many rows the focused multi-line input has, all of it shown.
  defp focused_rows(form, model, width) do
    case Enum.at(Model.focusable(form), min(model.focus, length(Model.focusable(form)) - 1)) do
      %Input{kind: "multiline", name: name} ->
        length(visual_rows(model.values[name] || "", field_width(width)))

      _ ->
        0
    end
  end

  defp input_lines(input, value, cursor, focused, inner, rows) do
    label = "   " <> pad(input.label <> if(input.required, do: " *", else: ""), @label_width)
    indent = String.duplicate(" ", String.length(label))

    lines =
      case input.kind do
        # Shown, never changed (an id).
        "readonly" ->
          Enum.map(Text.wrap(value, inner), &[{:plain, &1}])

        kind when kind in ["choice", "boolean"] ->
          shown = Enum.find_value(input.choices || [], value, &(&1.value == value && &1.label))
          [[{if(focused, do: :selected, else: :plain), "‹ #{shown} ›"}]]

        "multiline" ->
          editor(value, cursor, focused, inner, if(focused, do: rows, else: @resting_rows))

        # One line of text, wrapped when it is longer than the field; typing goes at its end.
        _ ->
          style = if focused, do: :selected, else: :plain
          rows = for {at, len} <- Text.rows(value, inner - 1), do: String.slice(value, at, len)
          rows = if focused, do: List.update_at(rows, -1, &(&1 <> "▏")), else: rows
          Enum.map(rows, &[{style, "[" <> pad(&1, inner) <> "]"}])
      end

    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> [{:dim, label} | line]
      {[{:dim, _} | _] = line, _} -> line
      {line, _} -> [{:plain, indent} | line]
    end)
  end

  # Every row the text takes in the field: `{line, start, length}`.
  defp visual_rows(value, inner) do
    value
    |> Text.lines()
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, l} ->
      for {at, len} <- Text.rows(line, inner - 1), do: {l, at, len}
    end)
  end

  # A text area: the rows around the cursor when it has the focus (the cursor is the
  # reversed cell), else the first rows; a line under it says what is out of sight.
  defp editor(value, cursor, focused, inner, room) do
    lines = Text.lines(value)
    all = visual_rows(value, inner)
    {cl, cc} = Text.cursor(value, cursor)

    at =
      Enum.find_index(all, fn {l, start, len} -> l == cl and cc < start + len end) ||
        Enum.find_index(all, fn {l, start, len} -> l == cl and cc == start + len end) || 0

    room = if room == :all, do: length(all), else: room
    start = if focused, do: at - div(room, 2), else: 0
    start = start |> min(length(all) - room) |> max(0)
    shown = Enum.slice(all, start, room)

    edge = if focused, do: :selected, else: :plain

    rows =
      Enum.map(shown, fn {l, from, len} = row ->
        text = lines |> Enum.at(l) |> String.slice(from, len)

        if focused and row == Enum.at(all, at) do
          {before, rest} = String.split_at(text, cc - from)
          {under, after_} = if rest == "", do: {" ", ""}, else: String.split_at(rest, 1)
          tail = pad(after_, inner - String.length(before) - 1)
          [{edge, "["}, {:plain, before}, {:cursor, under}, {:plain, tail}, {edge, "]"}]
        else
          [{edge, "["}, {:plain, pad(text, inner)}, {edge, "]"}]
        end
      end)

    empty = [{edge, "["}, {:plain, pad("", inner)}, {edge, "]"}]
    rows = rows ++ List.duplicate(empty, max(@least_rows - length(rows), 0))
    above = start
    below = length(all) - start - length(shown)

    more =
      [above > 0 && "↑ #{above} more above", below > 0 && "↓ #{below} more below"]
      |> Enum.filter(& &1)

    if more == [],
      do: rows,
      else: rows ++ [[{:dim, String.duplicate(" ", @label_width + 4) <> Enum.join(more, " · ")}]]
  end

  # A page longer than the screen: the focus of a form, or the selected row of a list,
  # stays in sight until the page is scrolled by hand (a page about one fact starts at
  # its top); arrows follow the selection again.
  defp window(lines, model, room) when length(lines) > room do
    last = length(lines) - room

    focus = Enum.find_index(lines, &cursor_line?/1) || Enum.find_index(lines, &selected_line?/1)
    follow = focus != nil and (model.scroll == nil or Model.form(model) != nil)
    start = if follow, do: focus - div(room, 2), else: model.scroll || 0

    Enum.slice(lines, start |> min(last) |> max(0), room)
  end

  defp window(lines, _model, _room), do: lines

  defp console_notice(%Model{console: %{error: error}}) when is_binary(error),
    do: [{:error, " Console: " <> error <> " · retrying boot"}]

  defp console_notice(%Model{console: %{action_error: error}}) when is_binary(error),
    do: [{:error, " Console: " <> error}]

  defp console_notice(model), do: notice(model)

  # Footer

  # The help, or the request line while `:` is open.
  defp footer_help(%Model{console: %{legend: legend}}, _help) when legend != nil, do: []

  defp footer_help(%Model{console: console, ask: text}, _help)
       when console != nil and is_binary(text),
       do: [[{:bold, " Request "}, {:plain, text}, {:cursor, " "}]]

  defp footer_help(%Model{console: console} = model, _help) when console != nil,
    do: AtlasTui.LegendView.affordance(model)

  defp footer_help(%Model{ask: text}, _help) when is_binary(text),
    do: [
      [{:bold, " : "}, {:plain, text}, {:cursor, " "}, {:dim, "   ↵ ask the agent   esc close"}]
    ]

  defp footer_help(_model, help), do: Enum.map(help, &[{:dim, " " <> &1}])

  defp help(%Model{console: console}, _long) when console != nil, do: ""

  defp help(model, long) do
    cond do
      not model.connected ->
        "q quit"

      Model.step_form(model) && multiline_focused?(model) ->
        "↵ new line   ↑↓←→ move   tab next field   ctrl-s keep   esc back to the plan"

      Model.step_form(model) ->
        "↑↓ move   type to edit   ctrl-s keep   esc back to the plan"

      plan = model.plan ->
        plan_help(plan)

      Model.form(model) && multiline_focused?(model) ->
        "↵ new line   ↑↓←→ move   tab next field   ctrl-s save   esc cancel"

      Model.form(model) ->
        "↑↓ move   ←→ choose   type to edit   ↵ next   ctrl-s save   esc cancel"

      confirm = Model.confirm(model) ->
        if confirm.confirm_to, do: "y confirm   n cancel", else: "↵ back"

      true ->
        Enum.map_join(Model.actions(model) ++ Model.links(model), "   ", &"#{&1.key} #{&1.label}") <>
          nav(model, long)
    end
  end

  defp plan_help(%Plan{state: "planning"}), do: "esc cancel"

  defp plan_help(%Plan{state: "proposed", steps: []}), do: ": ask again   esc close"

  defp plan_help(%Plan{state: "proposed"}),
    do:
      "↑↓ move   space keep/drop   e edit   ↵ run the kept steps   : change the request   esc cancel"

  defp plan_help(%Plan{state: "running"}), do: "esc stop after this step"
  defp plan_help(%Plan{}), do: "↵ close   : ask again   q quit"

  # The help's entries ("key what", three spaces apart) on as many lines as they need;
  # an entry is never split.
  defp help_lines(help, width) do
    help
    |> String.split("   ", trim: true)
    |> Enum.reduce([], fn
      entry, [] ->
        [entry]

      entry, [line | done] ->
        if String.length(line <> "   " <> entry) < width,
          do: [line <> "   " <> entry | done],
          else: [entry, line | done]
    end)
    |> Enum.reverse()
  end

  defp multiline_focused?(model) do
    items = Model.focusable(Model.step_form(model) || Model.form(model))
    match?(%Input{kind: "multiline"}, Enum.at(items, min(model.focus, length(items) - 1)))
  end

  defp cursor_line?(line), do: Enum.any?(line, &match?({:cursor, _}, &1))
  defp selected_line?(line), do: Enum.any?(line, &match?({:selected, _}, &1))

  defp nav(model, long) do
    move =
      cond do
        Model.parts(model) != [] and not Model.selecting?(model) -> "   ↑↓ scroll   ↵ open"
        Model.list(model) -> "   ↑↓ move   ↵ open"
        true -> ""
      end

    move = if Model.parts(model) != [], do: move <> "   tab next part", else: move
    move = if long, do: move <> "   pgup/pgdn scroll", else: move
    back = if model.back, do: "   esc back", else: ""
    move <> "   r refresh   : ask" <> back <> "   q quit"
  end

  defp notice(%Model{notice: nil}), do: []

  defp notice(%Model{notice: notice}) do
    tone =
      if notice[:tone] in ["ok", "error", "pending", "info"],
        do: String.to_atom(notice.tone),
        else: :info

    icon = %{ok: "✓", error: "✗", pending: "…", info: "i"}[tone]
    [{tone, " #{icon} #{notice.text}"}]
  end

  defp status(model, reconcile_seconds) do
    connection = if model.connected, do: {:ok, " ● connected"}, else: {:error, " ○ not connected"}

    updated =
      case model.updated do
        nil ->
          ""

        u ->
          " · #{reason(u.reason)} at #{u.at}" <>
            if(u.position, do: " · position #{u.position}", else: "")
      end

    hint =
      case model.last_hint do
        %{reason: "hint"} = h when h != model.updated -> " · last hint at #{h.at}"
        _ -> ""
      end

    [connection, {:dim, updated <> hint <> " · reconciles every #{reconcile_seconds}s"}]
  end

  defp reason("open"), do: "opened"
  defp reason("hint"), do: "updated by hint"
  defp reason("reconcile"), do: "reconciled"
  defp reason("stored"), do: "stored"
  defp reason("refused"), do: "refused"
  defp reason(other), do: to_string(other)

  # Text

  defp fit(segments, width) do
    {fitted, _} =
      Enum.reduce(segments, {[], width}, fn {style, text}, {acc, left} ->
        text = String.slice(text, 0, max(left, 0))
        {[{style, text} | acc], left - String.length(text)}
      end)

    Enum.reverse(fitted)
  end

  defp pad(text, n), do: String.pad_trailing(String.slice(text, 0, n), n)

  # Text no longer than `n`, ending in "…" when it had to be cut.
  defp cut(text, n) do
    if String.length(text) > n, do: String.slice(text, 0, max(n - 1, 0)) <> "…", else: text
  end

  defp pad_left(text, n), do: String.pad_leading(text, max(n, 0))

  @doc "A link's origin in a line: `since 3 Nov 15:10 · by melle · why`; empty without one."
  def origin_text(nil), do: ""

  def origin_text(origin) do
    since =
      case DateTime.from_iso8601(origin.since || "") do
        {:ok, at, _} -> "since " <> local(at)
        _ -> nil
      end

    by = origin.by && "by " <> origin.by
    [since, by, origin.cause] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  # In this machine's local time: "3 Nov 15:10".
  defp local(at) do
    {{y, mo, d}, {h, mi, _}} =
      at
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    Calendar.strftime(NaiveDateTime.from_erl!({{y, mo, d}, {h, mi, 0}}), "%-d %b %H:%M")
  end
end
