defmodule AtlasControl.ConsoleProjectionTest do
  use ExUnit.Case, async: true
  alias AtlasBFFContract.Console

  defp native do
    %{
      "path" => "/k/widget",
      "blocks" => [
        %{
          "id" => "items",
          "type" => "list",
          "props" => %{
            "rows" => [
              %{
                "id" => "one",
                "to" => "/k/widget/one",
                "links" => [
                  %{"label" => "External", "key" => "o", "url" => "https://example.org/one"}
                ]
              },
              %{
                "id" => "two",
                "to" => "/k/widget/two",
                "links" => [
                  %{"label" => "External", "key" => "o", "url" => "https://example.org/two"}
                ]
              }
            ]
          }
        }
      ],
      "markup" => []
    }
  end

  defp current,
    do: %{path: "/k/widget", context: "browse", generation: 1, on: "items", row: "one"}

  test "bindings and legend consume the same scoped action objects" do
    assert {:ok, page} = AtlasControl.Console.project(native(), 2)
    assert {:ok, projection} = Console.compile(page)
    assert {:ok, bindings} = Console.bindings(projection, current())
    action = bindings["o"]
    assert action in projection.actions
    assert action["props"]["scope"]["row"] == "one"
    assert {:ok, event} = Console.capture(projection, "o", current())
    assert {:ok, ^action} = Console.resolve(projection, event, current())
    assert {:ok, other} = Console.bindings(projection, %{current() | row: "two"})
    refute other["o"]["id"] == action["id"]

    refute Enum.any?(
             projection.actions,
             &(&1["props"]["scope"]["context"] == "form" and
                 &1["props"]["operation"]["name"] == "submit")
           )
  end

  test "captured actions are denied after any page context row or generation change" do
    {:ok, page} = AtlasControl.Console.project(native(), 2)
    {:ok, p} = Console.compile(page)
    {:ok, event} = Console.capture(p, "o", current())

    for changed <- [
          %{current() | row: "two"},
          %{current() | generation: 2},
          %{current() | context: "ask"},
          %{current() | path: "/"}
        ] do
      assert {:error, :stale_or_unavailable_action} = Console.resolve(p, event, changed)
    end

    {:ok, refreshed} = AtlasControl.Console.project(native(), 2)
    {:ok, next} = Console.compile(refreshed)
    assert {:error, :stale_or_unavailable_action} = Console.resolve(next, event, current())
    assert {:error, :unavailable_binding} = Console.capture(p, "F999", current())
  end

  test "unknown operations tokens scopes duplicate bindings and malformed legends fail closed" do
    {:ok, page} = AtlasControl.Console.project(native(), 2)
    first = Enum.find_index(page["blocks"], &(&1["type"] == "console_action"))

    for {field, value} <- [
          {"operation", %{"name" => "system"}},
          {"keys", ["Ctrl+Nonsense"]},
          {"scope", %{}},
          {"available", "yes"}
        ] do
      invalid = put_in(page, ["blocks", Access.at(first), "props", field], value)
      assert {:error, :invalid_console_projection} = Console.compile(invalid)
    end

    assert {:error, _} = Console.compile(%{page | "markup" => []})

    duplicate =
      update_in(page, ["blocks", Access.at(first + 1), "props", "keys"], fn _ -> ["Tab"] end)

    assert {:error, _} = Console.compile(duplicate)
    missing = put_in(page, ["blocks", Access.at(first), "props", "scope", "on"], "absent")
    assert {:error, _} = Console.compile(missing)

    assert {:error, _} =
             Console.compile(%{page | "blocks" => List.duplicate(hd(page["blocks"]), 513)})
  end

  test "finite operations validate destinations without evaluating them" do
    for to <- ["/k/widget/W%201", "/k/widget/%C3%A9", "/"] do
      assert Console.operation?(%{"name" => "open", "to" => to})
    end

    for to <- ["k/widget", "/k/widget/", "/k/widget/%FF", "/k/widget/%61"] do
      refute Console.operation?(%{"name" => "open", "to" => to})
    end

    for url <- [
          "javascript:alert(1)",
          "file:///tmp/a",
          "https://example.org:bad",
          "https://example.org/a b"
        ] do
      refute Console.operation?(%{"name" => "open_url", "url" => url})
    end

    refute Console.operation?(%{"name" => "quit", "to" => "/"})
    refute Console.key?("\n")
    refute Console.key?("\e")
  end

  test "projection expansion is bounded before materializing row actions" do
    page =
      put_in(
        native(),
        ["blocks", Access.at(0), "props", "rows"],
        for i <- 1..300 do
          %{
            "id" => "row#{i}",
            "links" => [%{"key" => "o", "label" => "Open", "url" => "https://example.org"}]
          }
        end
      )

    assert {:error, "Console projection exceeds action limit"} =
             AtlasControl.Console.project(page, 2)
  end
end
