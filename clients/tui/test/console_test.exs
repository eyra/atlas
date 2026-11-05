defmodule AtlasTui.ConsoleTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Console, Model, Protocol, View}

  defp fresh, do: %{Model.new("test") | console: Console.new()}

  defp welcome,
    do: %{
      "op" => "welcome",
      "env" => "test",
      "spec" => Protocol.version(),
      "surface" => "console"
    }

  defp page(path \\ "/k/widget", reason \\ "open") do
    %{
      "op" => "page",
      "path" => path,
      "title" => "Widgets",
      "reason" => reason,
      "blocks" => [
        %{
          "id" => "widgets",
          "type" => "list",
          "props" => %{
            "title" => "Widgets",
            "rows" => [
              %{"id" => "W1", "label" => "First", "to" => "/k/widget/W1"},
              %{"id" => "W2", "label" => "Second", "to" => "/k/widget/W2"}
            ]
          }
        }
      ]
    }
  end

  defp boot(target \\ "/k/widget") do
    %{
      "op" => "boot",
      "title" => "Atlas Console",
      "env" => "test",
      "spec" => Protocol.version(),
      "revision" => "rev1",
      "initial_to" => target,
      "active_tab" => "widgets",
      "tabs" => [
        %{"id" => "widgets", "label" => "Widgets", "to" => "/k/widget"},
        %{"id" => "parts", "label" => "Parts", "to" => "/k/part"},
        %{"id" => "open", "label" => "Open work", "to" => "/k/work"}
      ]
    }
  end

  defp handshake(model \\ fresh()) do
    {model, []} = Console.receive(model, welcome())
    {model, [{:send, %{"op" => "boot"}}]} = Console.receive(model, page("/"))
    model
  end

  defp ready do
    {model, [{:send, %{"op" => "open", "to" => "/k/widget"}}]} =
      Console.receive(handshake(), boot())

    {model, []} = Console.receive(model, page())
    model
  end

  defp screen(model, width \\ 80), do: model |> View.render(width, 20, 5) |> View.plain()

  test "compatibility page is discarded; native boot opens content inside persistent tabs" do
    model = handshake()
    assert model.path == nil
    assert model.blocks == []
    {model, [_]} = Console.receive(model, boot())
    {model, []} = Console.receive(model, page())
    assert model.console.phase == :ready
    assert model.console.active == "widgets"
    text = screen(model)

    for label <- ["Atlas Console · test", "▸ Widgets", "Parts", "Open work", "First"],
        do: assert(text =~ label)

    refute text =~ "Home"
    refute text =~ "tab next part"
  end

  test "only an explicit compatible welcome enables Console" do
    for welcome <- [
          Map.delete(welcome(), "surface"),
          Map.put(welcome(), "env", "prod"),
          Map.put(welcome(), "spec", "999.0.0")
        ] do
      {model, []} = Console.receive(fresh(), welcome)
      refute model.connected
      assert model.console.phase == :unsupported
      assert screen(model) =~ "did not acknowledge"
      {model, []} = Console.receive(model, page())
      assert model.path == nil
    end
  end

  test "invalid boot retains stale last good shell and recovers independently of content" do
    model = ready()

    for invalid <- [
          %{"op" => "boot", "error" => "State unavailable"},
          Map.put(boot(), "tabs", []),
          Map.put(boot(), "env", "prod"),
          put_in(boot(), ["tabs", Access.at(0), "to"], "/k/widget/W1"),
          put_in(boot(), ["tabs", Access.at(0), "label"], 42),
          Map.put(boot(), "initial_to", "/unknown"),
          Map.put(boot(), "tabs", [hd(boot()["tabs"]), hd(boot()["tabs"])])
        ] do
      {pending, [_]} = Console.refresh(model)
      {stale, []} = Console.receive(pending, invalid)
      assert stale.console.shell == model.console.shell
      assert stale.console.stale
      assert screen(stale) =~ "stale shell"
      assert screen(stale) =~ "▸ Widgets"
      {pending, [_]} = Console.refresh(stale)
      {recovered, []} = Console.receive(pending, Map.put(boot(), "revision", "rev2"))
      refute recovered.console.stale
      assert recovered.console.shell["revision"] == "rev2"
      assert recovered.path == model.path
    end
  end

  test "one boot in flight; unsolicited replies and interleaved compatibility pages have no authority" do
    model = fresh()
    assert Console.receive(model, boot()) == {model, []}
    model = handshake()
    assert Console.refresh(model) == {model, []}
    {model, []} = Console.receive(model, page("/"))
    assert model.path == nil
  end

  test "reconnect preserves actual edited form values, cursor and focus through all pages" do
    form = %{
      "op" => "page",
      "path" => "/k/widget/W1/edit",
      "reason" => "open",
      "blocks" => [
        %{
          "id" => "editor",
          "type" => "form",
          "props" => %{
            "title" => "Edit",
            "inputs" => [
              %{
                "name" => "title",
                "label" => "Title",
                "kind" => "text",
                "value" => "server default"
              }
            ],
            "submit_label" => "Save",
            "submit_to" => %{
              "endpoint" => "update",
              "params" => %{"kind" => "widget", "key" => "W1"}
            },
            "cancel_to" => "/k/widget/W1"
          }
        }
      ]
    }

    {model, []} = Console.receive(ready(), form)
    {model, []} = Model.key(model, {:char, "!"})
    assert model.values["title"] == "server default!"
    model = %{model | cursor: {0, 4}, focus: 1}
    disconnected = Model.disconnected(model)
    assert screen(disconnected) =~ "stale shell"
    pending = handshake(disconnected)
    assert pending.values == model.values
    assert pending.path == model.path

    {pending, [{:send, %{"to" => "/k/widget/W1/edit"}}]} =
      Console.receive(pending, boot(model.path))

    {pending, []} = Console.receive(pending, page("/"))
    assert pending.values == model.values
    {restored, []} = Console.receive(pending, form)
    assert restored.values == model.values
    assert restored.cursor == {0, 4}
    assert restored.focus == 1
    assert restored.console.phase == :ready
    assert restored.console.active == "widgets"
    {pending, [_]} = Console.refresh(restored)
    {pending, []} = Console.receive(pending, boot("/k/part"))
    assert pending.path == model.path
    {hinted, []} = Console.receive(pending, Map.put(form, "reason", "hint"))
    assert hinted.values == model.values
  end

  test "cycling operations wrap and reject stale/disconnected/modal navigation" do
    model = ready()
    {previous, [{:send, %{"to" => "/k/work"}}]} = Console.cycle(model, -1)
    {previous, []} = Console.receive(previous, page("/k/work"))
    assert previous.console.active == "open"
    {next, [{:send, %{"to" => "/k/widget"}}]} = Console.cycle(previous, 1)
    {next, []} = Console.receive(next, page())
    assert next.console.active == "widgets"

    for blocked <- [
          Model.disconnected(model),
          %{model | ask: "literal ?"},
          %{model | console: %{model.console | stale: true}}
        ] do
      assert Console.cycle(blocked, 1) == {blocked, []}
    end
  end

  test "deep links retain parent tab; tab return restores selected identity across reorder" do
    model = %{ready() | selected: 1}
    {other, [_]} = Console.cycle(model, 1)
    {other, []} = Console.receive(other, page("/k/part"))
    {back, [_]} = Console.cycle(other, -1)
    reordered = update_in(page(), ["blocks", Access.at(0), "props", "rows"], &Enum.reverse/1)
    {back, []} = Console.receive(back, reordered)
    assert back.selected == 0
    {detail, []} = Console.receive(back, page("/k/widget/W2"))
    assert detail.console.active == "widgets"
  end

  test "narrow viewport follows active tab and resize preserves shell and content" do
    {model, [_]} = Console.cycle(ready(), -1)
    {model, []} = Console.receive(model, page("/k/work"))

    for width <- [16, 20, 40, 100] do
      text = screen(model, width)
      assert text =~ "▸ Open work"
      assert length(String.split(text, "\n")) == 20
      assert Enum.all?(String.split(text, "\n"), &(String.length(&1) <= width))
    end

    assert screen(model, 16) =~ "‹"
    assert screen(model, 100) =~ "Widgets"
  end

  # Private approved-design fixtures, replaced by actual IS120 projection in the
  # integrated proof. No production key/legend defaults exist in the renderer.
  defp action(id, key, name, extra \\ %{}) do
    %{
      "id" => id,
      "type" => "console_action",
      "props" =>
        Map.merge(
          %{
            "label" => id,
            "keys" => [key],
            "operation" => %{"name" => name},
            "available" => true
          },
          extra
        )
    }
  end

  defp declared(page, context, actions) do
    page
    |> Map.update!("blocks", &(&1 ++ actions))
    |> Map.put("markup", [
      %{
        "kind" => "legend",
        "start" => hd(actions)["id"],
        "end" => List.last(actions)["id"],
        "props" => %{"title" => "Navigation", "context" => context}
      }
    ])
  end

  test "fixture-declared bindings alone cycle tabs and arrows retain list movement" do
    page =
      declared(page(), "browse", [
        action("next", "Tab", "tab_next"),
        action("previous", "Shift+Tab", "tab_previous"),
        action("down", "Down", "list_next")
      ])

    {model, []} = Console.receive(ready(), page)
    {down, []} = Model.key(model, :down)
    assert down.selected == 1
    {next, [{:send, %{"to" => "/k/part"}}]} = Model.key(down, :tab)
    assert Model.key(next, :tab) == {next, []}
    {previous, [{:send, %{"to" => "/k/work"}}]} = Model.key(model, :shift_tab)
    assert previous.console.expected == "/k/work"
    # Changing BFF keys changes execution; there is no local Tab fallback.
    custom = declared(page(), "browse", [action("next", "x", "tab_next")])
    {custom, []} = Console.receive(model, custom)
    assert Model.key(custom, :tab) == {custom, []}
    assert {_, [{:send, %{"to" => "/k/part"}}]} = Model.key(custom, {:char, "x"})
  end

  test "captured action cannot execute after page, context, row, availability or connection changes" do
    alias AtlasTui.Interactions
    projected = declared(page(), "browse", [action("down", "Down", "list_next")])
    {model, []} = Console.receive(ready(), projected)
    event = Interactions.capture(model, :down)
    assert event.id == "down"
    {changed, []} = Console.receive(model, Map.put(projected, "reason", "hint"))

    for stale <- [
          changed,
          %{model | selected: 1},
          %{model | ask: "draft"},
          Model.disconnected(model)
        ] do
      assert Interactions.dispatch(stale, event) == {stale, []}
    end

    disabled =
      declared(page(), "browse", [action("down", "Down", "list_next", %{"available" => false})])

    {disabled, []} = Console.receive(model, disabled)
    assert Model.key(disabled, :down) == {disabled, []}
    replaced = declared(page("/k/part"), "browse", [action("down", "Down", "list_next")])
    {replaced, []} = Console.receive(model, replaced)
    assert Interactions.dispatch(replaced, event) == {replaced, []}
    refute screen(model) =~ "console_action"
  end

  test "editing context traverses form focus and keeps literal question mark and actual values" do
    form = %{
      "op" => "page",
      "path" => "/k/widget/new",
      "blocks" => [
        %{
          "id" => "editor",
          "type" => "form",
          "props" => %{
            "title" => "Create",
            "inputs" => [
              %{"name" => "title", "label" => "Title", "kind" => "text", "value" => ""}
            ],
            "submit_label" => "Save",
            "submit_to" => %{"endpoint" => "create", "params" => %{"kind" => "widget"}}
          }
        }
      ]
    }

    form =
      declared(form, "form", [
        action("focus", "Tab", "focus_next"),
        action("back-focus", "Shift+Tab", "focus_previous")
      ])

    {model, []} = Console.receive(ready(), form)
    {model, []} = Model.key(model, {:char, "?"})
    assert model.values["title"] == "?"
    {model, []} = Model.key(model, :tab)
    assert model.focus == 1
    {model, []} = Model.key(model, :shift_tab)
    assert model.focus == 0
    assert model.path == "/k/widget/new"
    assert model.values["title"] == "?"
  end

  test "removed index falls back on boot reconciliation without replacing a valid deep link" do
    model = ready()

    shell =
      boot("/k/part") |> Map.put("tabs", tl(boot()["tabs"])) |> Map.put("active_tab", "parts")

    {pending, [_]} = Console.refresh(model)
    {fallback, [{:send, %{"to" => "/k/part"}}]} = Console.receive(pending, shell)
    assert fallback.path == "/k/widget"
    {detail, []} = Console.receive(model, page("/k/widget/W1"))
    {pending, [_]} = Console.refresh(detail)

    {preserved, []} =
      Console.receive(pending, %{shell | "initial_to" => detail.path, "active_tab" => nil})

    assert preserved.path == detail.path
    assert preserved.console.active == nil
  end
end
