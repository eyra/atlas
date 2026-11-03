defmodule AtlasTuiTest do
  use ExUnit.Case, async: true

  alias AtlasTui.{Blocks, Keys, Model, View}

  # What Control sends, by hand; the TUI knows blocks only, so the kind is made up.
  @list %{
    "op" => "page",
    "path" => "/k/thing",
    "title" => "Things",
    "back" => nil,
    "reason" => "open",
    "at" => "11:00:00",
    "position" => 3,
    "blocks" => [
      %{
        "type" => "list",
        "props" => %{
          "title" => "Things",
          "rows" => [
            %{"label" => "First", "detail" => "T-1", "to" => "/k/thing/T-1"},
            %{"label" => "Second", "detail" => "T-2 · Ready", "to" => "/k/thing/T-2"}
          ],
          "actions" => [%{"label" => "New thing", "key" => "n", "to" => "/k/thing/new"}]
        }
      }
    ]
  }

  @form %{
    "op" => "page",
    "path" => "/k/thing/new",
    "title" => "New thing",
    "back" => "/k/thing",
    "reason" => "open",
    "blocks" => [
      %{
        "type" => "form",
        "props" => %{
          "title" => "New thing",
          "submit_label" => "Create",
          "submit_to" => "/k/thing/new",
          "cancel_to" => "/k/thing",
          "inputs" => [
            %{"name" => "_key", "label" => "Id", "kind" => "text", "required" => true},
            %{
              "name" => "state",
              "label" => "State",
              "kind" => "choice",
              "choices" => [
                %{"value" => "", "label" => "—"},
                %{"value" => "a", "label" => "A"},
                %{"value" => "b", "label" => "B"}
              ]
            }
          ]
        }
      }
    ]
  }

  defp model(page),
    do: "test" |> Model.new() |> Model.message(%{"op" => "welcome"}) |> Model.message(page)

  defp press(model, keys) do
    Enum.reduce(keys, {model, []}, fn key, {m, effects} ->
      {m, more} = Model.key(m, key)
      {m, effects ++ more}
    end)
  end

  defp screen(model), do: model |> View.render(90, 20, 5) |> View.plain()

  test "keys: arrows, escape, enter, text" do
    assert Keys.parse("\e[A\e[Bx\r") == {[:up, :down, {:char, "x"}, :enter], ""}
    assert Keys.parse("ab\e") == {[{:char, "a"}, {:char, "b"}], "\e"}
    assert Keys.flush("\e") == [:esc]
    assert Keys.parse(<<127, 19, 3>>) == {[:backspace, :ctrl_s, :ctrl_c], ""}
    assert Keys.parse("é") == {[{:char, "é"}], ""}
  end

  test "an unknown or broken block becomes a fallback, and the rest still renders" do
    assert %Blocks.Fallback{type: "chart"} = Blocks.decode(%{"type" => "chart", "props" => %{}})

    assert %Blocks.Fallback{type: "item"} =
             Blocks.decode(%{"type" => "item", "props" => %{"fields" => []}})

    assert %Blocks.Item{title: "T", fields: []} =
             Blocks.decode(%{
               "type" => "item",
               "props" => %{"title" => "T", "fields" => [], "extra" => 1}
             })

    page = %{@list | "blocks" => [%{"type" => "chart", "props" => %{}} | @list["blocks"]]}
    assert screen(model(page)) =~ "(a chart block this TUI cannot show)"
    assert screen(model(page)) =~ "Second"
  end

  test "a list: move, open a row, run an action from Control's keys" do
    m = model(@list)
    text = screen(m)
    assert text =~ "Atlas · test"
    assert text =~ "› First"
    assert text =~ "n New thing"
    assert text =~ "opened at 11:00:00 · position 3"

    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/T-2"}}]} = press(m, [:down, :enter])
    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/new"}}]} = press(m, [{:char, "n"}])
    assert {_, [{:send, %{"op" => "refresh"}}]} = press(m, [{:char, "r"}])
    assert {_, [:quit]} = press(m, [{:char, "q"}])
  end

  test "a hint redraws the list and keeps the selected row" do
    {m, _} = press(model(@list), [:down])
    hinted = Model.message(m, %{@list | "reason" => "hint", "position" => 4})
    assert hinted.selected == 1
    assert screen(hinted) =~ "updated by hint at 11:00:00 · position 4"

    reconciled = Model.message(hinted, %{@list | "reason" => "reconcile", "at" => "11:00:05"})
    assert screen(reconciled) =~ "reconciled at 11:00:05 · position 3 · last hint at 11:00:00"
  end

  test "a form: type, choose, save sends the values" do
    {m, effects} =
      press(model(@form), [
        {:char, "T"},
        {:char, "-"},
        {:char, "9"},
        :backspace,
        {:char, "1"},
        :down,
        :right,
        :right
      ])

    assert effects == []
    assert screen(m) =~ "[T-1"
    assert screen(m) =~ "‹ B ›"

    assert {%{waiting: true},
            [
              {:send,
               %{
                 "op" => "submit",
                 "to" => "/k/thing/new",
                 "values" => %{"_key" => "T-1", "state" => "b"}
               }}
            ]} =
             press(m, [:ctrl_s])

    assert {_, [{:send, %{"op" => "submit"}}]} = press(m, [:down, :enter])
    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing"}}]} = press(m, [:esc])
  end

  test "a long text shows its end while typing, its start otherwise" do
    long = String.duplicate("abcdefghij", 4)
    {m, _} = press(model(@form), Enum.map(String.graphemes(long), &{:char, &1}))
    assert screen(m) =~ "[…" <> String.slice(long, -28..-1//1) <> "▏]"
    {m, _} = press(m, [:down])
    assert screen(m) =~ "[" <> String.slice(long, 0, 29) <> "…]"
  end

  test "q is text in a form, not quit" do
    {m, effects} = press(model(@form), [{:char, "q"}])
    assert effects == []
    assert m.values["_key"] == "q"
  end

  test "a confirm: y submits, n goes back; without confirm_to it only goes back" do
    confirm = %{
      @form
      | "blocks" => [
          %{
            "type" => "confirm",
            "props" => %{
              "title" => "Delete T-1?",
              "text" => "Gone.",
              "confirm_label" => "Delete",
              "confirm_to" => "/k/thing/T-1/delete",
              "cancel_to" => "/k/thing/T-1"
            }
          }
        ]
    }

    assert {_, [{:send, %{"op" => "submit", "to" => "/k/thing/T-1/delete"}}]} =
             press(model(confirm), [{:char, "y"}])

    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/T-1"}}]} =
             press(model(confirm), [{:char, "n"}])

    refusal =
      put_in(confirm, ["blocks", Access.at(0), "props"], %{
        "title" => "Cannot",
        "text" => "Still has 2.",
        "cancel_to" => "/k/thing/T-1"
      })

    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/T-1"}}]} =
             press(model(refusal), [{:char, "y"}, :enter])
  end

  test "notices and a lost connection are shown, never old content as current" do
    m =
      Model.message(model(@list), %{
        "op" => "notice",
        "tone" => "pending",
        "text" => "Sent to State; waiting until it is stored…"
      })

    assert screen(m) =~ "… Sent to State"

    gone = Model.disconnected(m)
    assert screen(gone) =~ "Not connected to Control. Retrying…"
    refute screen(gone) =~ "First"
  end
end
