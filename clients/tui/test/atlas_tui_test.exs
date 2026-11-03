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
          "actions" => [%{"label" => "Create thing", "key" => "c", "to" => "/k/thing/new"}]
        }
      }
    ]
  }

  @form %{
    "op" => "page",
    "path" => "/k/thing/new",
    "title" => "Create thing",
    "back" => "/k/thing",
    "reason" => "open",
    "blocks" => [
      %{
        "type" => "form",
        "props" => %{
          "title" => "Create thing",
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
    assert Keys.parse("\e[H\e[F\e[1~\e[4~") == {[:home, :end, :home, :end], ""}
  end

  test "the header names the environment; prod stands out in white on red" do
    ansi = fn env ->
      env |> Model.new() |> View.render(90, 20, 5) |> View.to_ansi() |> IO.iodata_to_binary()
    end

    assert ansi.("prod") =~ "\e[0;1;97;41m Atlas · prod"
    assert ansi.("test") =~ "\e[0;1m Atlas · test"
    refute ansi.("test") =~ "41m"
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
    assert text =~ "c Create thing"
    assert text =~ "opened at 11:00:00 · position 3"

    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/T-2"}}]} = press(m, [:down, :enter])
    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/new"}}]} = press(m, [{:char, "c"}])
    assert {_, [{:send, %{"op" => "refresh"}}]} = press(m, [{:char, "r"}])
    assert {_, [:quit]} = press(m, [{:char, "q"}])
  end

  test "a link opens its web address: the item's, and the selected row's" do
    url = "https://example.org/things/2"
    link = %{"label" => "Open in browser", "key" => "o", "url" => url}
    [list] = @list["blocks"]
    rows = List.update_at(list["props"]["rows"], 1, &Map.put(&1, "links", [link]))
    m = model(%{@list | "blocks" => [put_in(list["props"]["rows"], rows)]})

    # Only the selected row's link: none on the first row.
    refute screen(m) =~ "o Open in browser"
    assert {_, []} = press(m, [{:char, "o"}])

    {m, _} = press(m, [:down])
    assert screen(m) =~ "c Create thing   o Open in browser   ↑↓ move"
    {m, effects} = press(m, [{:char, "o"}])
    assert effects == [{:open_url, url}]
    assert screen(m) =~ "i Opened #{url} in the browser"

    item = %{
      "type" => "item",
      "props" => %{"title" => "Thing T-2", "fields" => [], "links" => [link]}
    }

    assert {_, [{:open_url, ^url}]} =
             press(model(%{@list | "blocks" => [item]}), [{:char, "o"}])

    # A help too long for one line goes on on the next; no entry is cut or lost.
    narrow =
      model(%{@list | "back" => "/", "blocks" => [item]})
      |> View.render(40, 20, 5)
      |> View.plain()
      |> String.split("\n")

    help = Enum.filter(narrow, &(&1 =~ ~r/Open in browser|esc back|q quit/))
    assert help == [" o Open in browser   r refresh   : ask", " esc back   q quit"]
    assert length(narrow) == 20

    # Anything but http and https is never opened.
    for bad <- ["file:///etc/passwd", "javascript:alert(1)", "https://", "https://a b"] do
      item = put_in(item, ["props", "links"], [%{link | "url" => bad}])
      {m, effects} = press(model(%{@list | "blocks" => [item]}), [{:char, "o"}])
      assert effects == []
      assert screen(m) =~ "Not opened: only http and https addresses"
    end

    assert AtlasTui.Browser.open("file:///etc/passwd", %{}) == {:error, :not_http}
    assert AtlasTui.Browser.command(%{"browser" => "/tmp/stand-in"}) == "/tmp/stand-in"
    assert AtlasTui.Browser.command(%{}) in ["open", "xdg-open"]
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

  test "a long text wraps in its field instead of being cut" do
    long = String.duplicate("abcdefghij ", 12) |> String.trim()
    {m, _} = press(model(@form), Enum.map(String.graphemes(long), &{:char, &1}))
    text = screen(m)
    assert text =~ "[abcdefghij abcdefghij"
    assert text =~ "abcdefghij▏"
    # Every word is on screen, over more than one row.
    assert text |> String.split("abcdefghij") |> length() == 13
    {m, _} = press(m, [:down])
    refute screen(m) =~ "▏"
    assert screen(m) |> String.split("abcdefghij") |> length() == 13
  end

  @notes_form update_in(@form, ["blocks", Access.at(0), "props", "inputs"], fn inputs ->
                inputs ++
                  [%{"name" => "notes", "label" => "Notes", "kind" => "multiline", "value" => ""}]
              end)

  defp type(text), do: Enum.map(String.graphemes(text), &{:char, &1})

  test "a multi-line input: enter starts a new line, arrows move, ctrl-s saves the lines" do
    {m, _} = press(model(@notes_form), [:down, :down])
    assert screen(m) =~ "↵ new line"

    {m, effects} =
      press(
        m,
        type("## Why") ++ [:enter, :enter] ++ type("Because.") ++ [:enter] ++ type("- one")
      )

    assert effects == []
    assert m.values["notes"] == "## Why\n\nBecause.\n- one"

    # Up twice, to the end of "Because."… then a blank line before the list.
    {m, _} = press(m, [:up, :end, :enter])
    assert m.values["notes"] == "## Why\n\nBecause.\n\n- one"

    # Backspace at the start of a line joins it to the line above.
    {m, _} = press(m, [:down, :home, :backspace])
    assert m.values["notes"] == "## Why\n\nBecause.\n- one"

    # Typing goes where the cursor is.
    {m, _} = press(m, [:left, :left] ++ type("!"))
    assert m.values["notes"] == "## Why\n\nBecause!.\n- one"

    assert {_, [{:send, %{"op" => "submit", "values" => %{"notes" => notes}}}]} =
             press(m, [:ctrl_s])

    assert notes == m.values["notes"]

    # Past the first line, up leaves the input; tab always does.
    {m2, _} = press(m, [:up, :up, :up])
    assert Model.focusable(Model.form(m2)) |> Enum.at(m2.focus) |> Map.get(:name) == "state"
    {m3, _} = press(m, [:tab])
    assert Enum.at(Model.focusable(Model.form(m3)), m3.focus) == :submit
  end

  test "a long multi-line input scrolls to keep the cursor in sight" do
    text = Enum.map_join(1..40, "\n", &"line #{&1}")

    page =
      put_in(
        @notes_form,
        ["blocks", Access.at(0), "props", "inputs", Access.at(2), "value"],
        text
      )

    {m, _} = press(model(page), [:down, :down])
    # Moving down into it starts at its first line.
    assert screen(m) =~ "[line 1 "
    assert screen(m) =~ "more below"
    refute screen(m) =~ "line 40"

    {m, _} = press(m, List.duplicate(:down, 38))
    assert screen(m) =~ "line 39"
    assert screen(m) =~ "more above"
    refute screen(m) =~ "[line 1 "
    assert screen(m) =~ "[ Create ]"

    # Out of focus it shows its start, and how much more there is.
    {m, _} = press(m, [:tab])
    assert screen(m) =~ "[line 1 "
    assert screen(m) =~ "↓ 32 more below"
  end

  test "an item shows text with its line breaks, blank lines and sections" do
    notes =
      "## Why\n\nBecause it is long enough to wrap around the edge of the screen here.\n\n- one\n- two"

    item = %{
      @list
      | "blocks" => [
          %{
            "type" => "item",
            "props" => %{
              "title" => "Thing T-1: " <> String.duplicate("a long title ", 10),
              "fields" => [%{"label" => "Notes", "value" => notes}]
            }
          }
        ]
    }

    lines = model(item) |> View.render(60, 30, 5) |> View.plain() |> String.split("\n")
    at = Enum.find_index(lines, &(&1 =~ "## Why"))
    assert Enum.at(lines, at + 1) |> String.trim() == ""
    assert Enum.at(lines, at + 2) =~ "Because it is long"
    assert Enum.at(lines, at + 3) =~ ~r/^\s+\S/
    assert Enum.at(lines, at + 4) |> String.trim() == ""
    assert Enum.at(lines, at + 5) =~ "- one"
    assert Enum.at(lines, at + 6) =~ "- two"
    # The title wraps instead of being cut.
    assert lines |> Enum.join() |> String.split("a long title") |> length() == 11
  end

  test "a page longer than the screen scrolls, and keeps a selected row in sight" do
    long = Enum.map_join(1..30, "\n", &"line #{&1}")

    page = fn rows ->
      %{
        @list
        | "blocks" => [
            %{
              "type" => "item",
              "props" => %{
                "title" => "Thing T-1",
                "fields" => [%{"label" => "Notes", "value" => long}]
              }
            },
            %{
              "type" => "list",
              "props" => %{"title" => "Parts", "rows" => rows, "empty" => "No parts yet."}
            }
          ]
      }
    end

    m = model(page.([]))
    assert screen(m) =~ "pgup/pgdn scroll"
    refute screen(m) =~ "No parts yet."
    {m, _} = press(m, [:page_down, :page_down, :page_down])
    assert screen(m) =~ "No parts yet."
    {m, _} = press(m, [:page_up, :page_up, :page_up])
    assert screen(m) =~ "line 1\n"

    # The page opens at its top; moving in the list under it brings the row in sight.
    m = model(page.([%{"label" => "Wheel", "to" => "/k/part/P-1"}]))
    refute screen(m) =~ "› Wheel"
    {m, _} = press(m, [:down])
    assert screen(m) =~ "› Wheel"
  end

  test "a read-only input is shown but never takes focus or typing" do
    page =
      update_in(@form, ["blocks", Access.at(0), "props", "inputs"], fn inputs ->
        [
          %{"name" => "_key", "label" => "Id", "kind" => "readonly", "value" => "T-01"}
          | tl(inputs)
        ]
      end)

    {m, _} = press(model(page), [{:char, "x"}])
    assert screen(m) =~ ~r/Id\s+T-01/
    assert m.values["_key"] == "T-01"
    assert m.values["state"] == ""
    assert Model.focusable(Model.form(m)) |> hd() |> Map.get(:name) == "state"
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

  describe "markup" do
    # A thing in a border, then its parts in a section, as Control sends a fact's page.
    @marked %{
      "op" => "page",
      "path" => "/k/thing/T-1",
      "title" => "Thing T-1",
      "back" => "/k/thing",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "item",
          "type" => "item",
          "props" => %{
            "title" => "Thing T-1: First",
            "fields" => [%{"label" => "Id", "value" => "T-1"}]
          }
        },
        %{
          "id" => "parts",
          "type" => "list",
          "props" => %{
            "rows" => [%{"label" => "Wheel", "detail" => "P-1", "to" => "/k/part/P-1"}]
          }
        }
      ],
      "markup" => [
        %{"kind" => "border", "start" => "item", "end" => "item", "props" => %{}},
        %{
          "kind" => "section",
          "start" => "parts",
          "end" => "parts",
          "props" => %{"title" => "Parts"}
        }
      ]
    }

    test "a border is drawn around its blocks, a section heads its own" do
      lines = model(@marked) |> View.render(40, 20, 5) |> View.plain() |> String.split("\n")

      assert Enum.slice(lines, 2, 9) == [
               " ┌────────────────────────────────────┐",
               " │ Thing T-1: First                   │",
               " │                                    │",
               " │   Id              T-1              │",
               " └────────────────────────────────────┘",
               "",
               " Parts ────────────────────────────────",
               "",
               " › Wheel"
             ]
    end

    test "markup of an unknown kind is left out; the blocks still show" do
      page =
        update_in(
          @marked["markup"],
          &[%{"kind" => "sparkle", "start" => "item", "end" => "item"} | &1]
        )

      assert %Model{markup: [%{"kind" => "border"}, %{"kind" => "section"}]} = model(page)
      assert screen(model(page)) =~ "┌"
    end

    test "markup that does not nest is left out whole, and the page renders flat" do
      crossing = [
        %{"kind" => "border", "start" => "item", "end" => "parts", "props" => %{}},
        %{
          "kind" => "section",
          "start" => "parts",
          "end" => "parts",
          "props" => %{"title" => "Parts"}
        },
        %{
          "kind" => "highlight",
          "start" => "item",
          "end" => "nowhere",
          "props" => %{"tone" => "ok"}
        }
      ]

      m = model(%{@marked | "markup" => crossing})
      assert m.markup == []
      refute screen(m) =~ "┌"
      assert screen(m) =~ "Thing T-1: First"
      assert screen(m) =~ "Wheel"
    end

    test "a page without ids or markup renders as before" do
      assert %Model{ids: ["#0"], markup: []} = model(@list)
      assert screen(model(@list)) =~ "Things"
    end
  end

  test "the view knows every block and kind of markup in Control's contract" do
    schema = AtlasContract.Blocks.__schema__()
    known = View.known()

    for %{name: name} <- schema.blocks,
        do: assert(Atom.to_string(name) in known.blocks, "the TUI does not draw block #{name}")

    for %{name: name} <- schema.markup,
        do: assert(Atom.to_string(name) in known.markup, "the TUI does not know markup #{name}")
  end
end
