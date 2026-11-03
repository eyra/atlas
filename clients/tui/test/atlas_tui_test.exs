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
  defp tall(model), do: model |> View.render(90, 30, 5) |> View.plain()

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
    assert text =~ "n New thing"
    assert text =~ "opened at 11:00:00 · position 3"

    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/T-2"}}]} = press(m, [:down, :enter])
    assert {_, [{:send, %{"op" => "open", "to" => "/k/thing/new"}}]} = press(m, [{:char, "n"}])
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
    assert screen(m) =~ "n New thing   o Open in browser   ↑↓ move"
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

  # A page in two parts, as Control sends an item's page: its content, and its references
  # (two lists) in columns.
  defp parted(lines) do
    notes = Enum.map_join(1..lines, "\n", &"Line #{&1} of the notes")
    row = fn label, detail, to -> %{"label" => label, "detail" => detail, "to" => to} end

    @list
    |> Map.put("markup", [])
    |> Map.merge(%{
      "back" => "/k/thing",
      "blocks" => [
        %{
          "id" => "item",
          "type" => "item",
          "props" => %{
            "title" => "Thing T-1: One",
            "fields" => [%{"label" => "Notes", "value" => notes}]
          }
        },
        %{
          "id" => "list:parts",
          "type" => "list",
          "props" => %{
            "rows" => [row.("Wheel", "P-1", "/k/part/P-1"), row.("Axle", "P-2", "/k/part/P-2")]
          }
        },
        %{
          "id" => "parent:of",
          "type" => "list",
          "props" => %{"rows" => [row.("W-1", "Widget", "/k/widget/W-1")]}
        }
      ],
      "markup" => [
        %{
          "kind" => "columns",
          "start" => "item",
          "end" => "parent:of",
          "props" => %{"count" => 2}
        },
        %{
          "kind" => "border",
          "start" => "item",
          "end" => "item",
          "props" => %{"title" => "Content"}
        },
        %{
          "kind" => "border",
          "start" => "list:parts",
          "end" => "parent:of",
          "props" => %{"title" => "References"}
        },
        %{
          "kind" => "section",
          "start" => "list:parts",
          "end" => "list:parts",
          "props" => %{"title" => "Parts"}
        },
        %{
          "kind" => "section",
          "start" => "parent:of",
          "end" => "parent:of",
          "props" => %{"title" => "Of widget"}
        }
      ]
    })
    |> model()
  end

  test "a page in parts: a long content never hides the references" do
    m = parted(60)
    assert Model.parts(m) == [["item"], ["list:parts", "parent:of"]]
    text = tall(m)

    # One above the other on a narrow screen; the content cut, saying how much more.
    assert text =~ ~r/┌─ Content ─+┐\n(.*\n)+.*… \d+ more lines.*\n.*└─+┘\n.*┌─ References/u
    assert text =~ "› Wheel"
    assert text =~ "W-1"
    assert text =~ "tab next part"
    assert length(String.split(text, "\n")) == 30

    # The rows of both lists are one selection.
    {down, _} = press(m, [:down, :down])
    assert tall(down) =~ "› W-1"
    assert {_, [{:send, %{"to" => "/k/widget/W-1"}}]} = press(down, [:enter])

    # Tab: the arrows scroll the content now, and leave the selection alone.
    {scrolled, _} = press(m, [:tab, :down, :down])
    assert scrolled.selected == 0
    assert tall(scrolled) =~ "↑ 2 lines above"
    assert tall(scrolled) =~ "↑↓ scroll"
    refute tall(scrolled) =~ "Thing T-1: One"
    assert tall(scrolled) =~ "› Wheel"
    {back, _} = press(scrolled, [:shift_tab, :down])
    assert back.selected == 1

    # Side by side on a wide screen.
    wide = m |> View.render(150, 20, 5) |> View.plain()
    assert wide =~ ~r/┌─ Content ─+┐ +┌─ References ─+┐/u

    # Content that fits is not cut, and says nothing about more.
    refute tall(parted(2)) =~ "more line"
  end

  test "rows start with the id, in a column as wide as the longest; a long label is cut" do
    rows = [
      %{"id" => "T-1", "label" => "Short", "detail" => "Testing · 1/2", "to" => "/k/thing/T-1"},
      %{
        "id" => "T-1234",
        "label" => String.duplicate("A very long label ", 6),
        "detail" => "Merged",
        "to" => "/k/thing/T-1234"
      }
    ]

    [list] = @list["blocks"]
    lines = model(%{@list | "blocks" => [put_in(list["props"]["rows"], rows)]}) |> screen()
    [first, second] = Regex.scan(~r/^ (?:›| ) T-1.*$/mu, lines) |> Enum.map(&hd/1)

    assert first =~ ~r/^ › T-1     Short\s+  Testing · 1\/2$/u
    assert second =~ ~r/^   T-1234  A very long label .*…  Merged$/u

    # The labels and the details each start in one column.
    at = fn line, text -> line |> String.split(text) |> hd() |> String.length() end
    assert at.(first, "Short") == at.(second, "A very")
    assert String.length(first) <= 90 and String.length(second) <= 90
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

  test "a value set by a fact shows since when, by whom and why, under it" do
    item = %{
      @list
      | "blocks" => [
          %{
            "type" => "item",
            "props" => %{
              "title" => "Thing T-1",
              "fields" => [
                %{
                  "label" => "Linked to",
                  "value" => "ada",
                  "origin" => %{
                    "since" => "2026-11-03T14:10:00Z",
                    "by" => "ada",
                    "cause" => "tested"
                  }
                }
              ]
            }
          }
        ]
    }

    lines = model(item) |> View.render(80, 20, 5) |> View.plain() |> String.split("\n")
    at = Enum.find_index(lines, &(&1 =~ "Linked to"))
    assert Enum.at(lines, at) =~ "ada"
    assert Enum.at(lines, at + 1) =~ ~r/since 3 Nov \d\d:10 · by ada · tested/
    assert View.origin_text(nil) == ""
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
               " › Wheel                            P-1"
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
