defmodule AtlasTui.View do
  @moduledoc """
  Draws the model as lines for a terminal of `width` × `height`. Pure, so tests can read
  the screen. Each line is a list of `{style, text}` segments; `to_ansi/1` adds colour.
  """

  alias AtlasTui.Blocks.{Confirm, Fallback, Form, Input, Item}
  alias AtlasTui.Blocks.List, as: ListBlock
  alias AtlasTui.Model

  @label_width 16

  @doc "The screen: exactly `height` lines of plain segments."
  def render(%Model{} = model, width, height, reconcile_seconds) do
    header = [
      [
        {:bold, " Atlas · #{model.env}"},
        {:dim, pad_left(model.title <> " ", width - 13 - String.length(model.env))}
      ],
      [{:dim, String.duplicate("─", width)}]
    ]

    footer = [
      [{:dim, " " <> help(model)}],
      [{:dim, String.duplicate("─", width)}],
      notice(model),
      status(model, reconcile_seconds)
    ]

    room = max(height - length(header) - length(footer), 1)
    body = model |> body(width) |> window(model, room)
    body = body ++ Elixir.List.duplicate([], room - length(body))

    Enum.map(header ++ body ++ footer, &fit(&1, width))
  end

  @doc "The screen as plain text, for tests and evidence."
  def plain(lines),
    do:
      Enum.map_join(lines, "\n", fn line ->
        line |> Enum.map_join(&elem(&1, 1)) |> String.trim_trailing()
      end)

  @doc "The screen as ANSI, ready to write from the top-left corner."
  def to_ansi(lines) do
    rows = Enum.map(lines, fn line -> [Enum.map(line, &segment/1), "\e[0m\e[K"] end)
    ["\e[H", Enum.intersperse(rows, "\r\n"), "\e[J"]
  end

  defp segment({:plain, text}), do: ["\e[0m", text]
  defp segment({:bold, text}), do: ["\e[0;1m", text]
  defp segment({:dim, text}), do: ["\e[0;2m", text]
  defp segment({:selected, text}), do: ["\e[0;7m", text]
  defp segment({:ok, text}), do: ["\e[0;32m", text]
  defp segment({:error, text}), do: ["\e[0;31m", text]
  defp segment({:pending, text}), do: ["\e[0;33m", text]
  defp segment({:info, text}), do: ["\e[0;36m", text]

  # Body

  defp body(%Model{connected: false, closed: false}, _width) do
    [
      [],
      [{:error, " Not connected to Control. Retrying…"}],
      [{:dim, " Nothing old is shown as if it were current."}]
    ]
  end

  defp body(%Model{blocks: []}, _width), do: [[], [{:dim, " Waiting for Control…"}]]

  defp body(model, width) do
    model.blocks |> Enum.map(&block(&1, model, width)) |> Enum.intersperse([[]]) |> Enum.concat()
  end

  defp block(%ListBlock{} = list, model, _width) do
    rows =
      case list.rows do
        [] ->
          [[{:dim, "   " <> (list.empty || "Nothing here.")}]]

        rows ->
          rows
          |> Enum.with_index()
          |> Enum.map(fn {row, i} ->
            style = if i == model.selected, do: :selected, else: :plain
            marker = if i == model.selected, do: " › ", else: "   "

            [
              {style, marker <> pad(row.label, 40) <> "  "},
              {if(i == model.selected, do: :selected, else: :dim), row.detail || ""}
            ]
          end)
      end

    [[{:bold, " " <> list.title}], []] ++ rows
  end

  defp block(%Item{} = item, _model, width) do
    fields =
      Enum.flat_map(item.fields, fn pair ->
        [first | rest] = wrap(pair.value || "—", width - @label_width - 4)

        [
          [{:dim, "   " <> pad(pair.label, @label_width)}, {:plain, first}]
          | Enum.map(rest, &[{:plain, String.duplicate(" ", @label_width + 3) <> &1}])
        ]
      end)

    [[{:bold, " " <> item.title}], []] ++ fields
  end

  defp block(%Form{} = form, model, width) do
    items = Model.focusable(form)
    focus = min(model.focus, length(items) - 1)

    errors =
      Enum.flat_map(form.errors || [], fn error ->
        [first | rest] = wrap(error, width - 7)
        [[{:error, "   ! " <> first}] | Enum.map(rest, &[{:error, "     " <> &1}])]
      end)

    inputs =
      form.inputs
      |> Enum.with_index()
      |> Enum.map(fn {input, i} ->
        input_line(input, model.values[input.name] || "", i == focus)
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
          Enum.map(wrap(hint, width - 6), &[{:dim, "   " <> &1}])

        _ ->
          []
      end

    [[{:bold, " " <> form.title}], []] ++
      errors ++ if(errors == [], do: [], else: [[]]) ++ inputs ++ [[]] ++ buttons ++ [[]] ++ hint
  end

  defp block(%Confirm{} = confirm, _model, width) do
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

    [[{:bold, " " <> confirm.title}], []] ++
      Enum.map(wrap(confirm.text, width - 4), &[{:plain, "   " <> &1}]) ++ [[]] ++ choices
  end

  defp block(%Fallback{type: type}, _model, _width),
    do: [[{:dim, "   (a #{type || "?"} block this TUI cannot show)"}]]

  defp input_line(input, value, focused) do
    label = "   " <> pad(input.label <> if(input.required, do: " *", else: ""), @label_width)

    field =
      case input.kind do
        kind when kind in ["choice", "boolean"] ->
          shown = Enum.find_value(input.choices || [], value, &(&1.value == value && &1.label))
          "‹ #{shown} ›"

        _ ->
          "[" <> pad(visible(value, focused, 30), 30) <> "]"
      end

    [{:dim, label}, {if(focused, do: :selected, else: :plain), field}]
  end

  # A focused input shows its end, where typing happens; others show their start.
  defp visible(value, true, room) do
    if String.length(value) < room,
      do: value <> "▏",
      else: "…" <> String.slice(value, -(room - 2)..-1//1) <> "▏"
  end

  defp visible(value, false, room) do
    if String.length(value) <= room, do: value, else: String.slice(value, 0, room - 1) <> "…"
  end

  # Keep the selected row of a long list on screen.
  defp window(lines, model, room) when length(lines) > room do
    case Model.list(model) do
      %ListBlock{} ->
        target = model.selected + 2
        start = min(max(target - div(room, 2), 0), length(lines) - room)
        Enum.slice(lines, start, room)

      nil ->
        Enum.take(lines, room)
    end
  end

  defp window(lines, _model, _room), do: lines

  # Footer

  defp help(model) do
    cond do
      not model.connected ->
        "q quit"

      Model.form(model) ->
        "↑↓ move   ←→ choose   type to edit   ↵ next   ctrl-s save   esc cancel"

      confirm = Model.confirm(model) ->
        if confirm.confirm_to, do: "y confirm   n cancel", else: "↵ back"

      true ->
        Enum.map_join(Model.actions(model), "   ", &"#{&1.key} #{&1.label}") <> nav(model)
    end
  end

  defp nav(model) do
    move = if Model.list(model), do: "   ↑↓ move   ↵ open", else: ""
    back = if model.back, do: "   esc back", else: ""
    move <> "   r refresh" <> back <> "   q quit"
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
  defp pad_left(text, n), do: String.pad_leading(text, max(n, 0))

  defp wrap(text, width) do
    width = max(width, 10)

    text
    |> String.split("\n")
    |> Enum.flat_map(fn paragraph ->
      paragraph
      |> String.split(" ")
      |> Enum.reduce([""], fn word, [line | done] ->
        cond do
          line == "" -> [word | done]
          String.length(line) + 1 + String.length(word) <= width -> [line <> " " <> word | done]
          true -> [word, line | done]
        end
      end)
      |> Enum.reverse()
    end)
  end
end
