defmodule AtlasControl.PagesTest do
  use ExUnit.Case, async: true

  alias AtlasControl.{FakeStore, Pages}

  @d FakeStore.description()

  defp fact(key, values, version \\ "v1"),
    do: %{"key" => key, "values" => values, "version" => version}

  test "only kinds without a parent are on top; one top kind opens its list at once" do
    assert Pages.top_kinds(@d) == ["widget"]
    assert Pages.reads(:home, @d) == [{"widget", %{}}]
    page = Pages.render(:home, @d, [%{"facts" => []}])
    assert %{title: "Widgets", back: nil, blocks: [%{"type" => "list"}]} = page
  end

  test "routes and paths are each other's inverse" do
    for route <- [
          {:list, "widget"},
          {:new, "widget"},
          {:item, "widget", "W-1"},
          {:edit, "widget", "W 1"},
          {:delete, "widget", "W/1"}
        ] do
      assert Pages.route(Pages.path(route)) == route
    end
  end

  test "a list shows each fact's primary value, key and chosen values, sorted by key" do
    answer = %{
      "facts" => [
        fact("W-2", %{"title" => "Two", "done" => true}),
        fact("W-1", %{"title" => "One", "shade" => "dark"})
      ]
    }

    %{blocks: [%{"props" => list}]} = Pages.render({:list, "widget"}, @d, [answer])

    assert [
             %{"label" => "One", "detail" => "W-1 · Dark", "to" => "/k/widget/W-1"},
             %{"label" => "Two", "detail" => "W-2 · done"}
           ] = list["rows"]

    assert [%{"key" => "n", "to" => "/k/widget/new", "label" => "New widget"}] = list["actions"]
  end

  test "an item shows every described property, and a list of the facts that point at it" do
    answer = %{
      "fact" => fact("W-1", %{"title" => "One", "shade" => "light"}),
      "incoming" => %{"of_widget" => ["P-1"]}
    }

    parts = %{"facts" => [fact("P-1", %{"title" => "Wheel"})]}

    assert Pages.reads({:item, "widget", "W-1"}, @d) == [
             {"widget", %{"key" => "W-1"}},
             {"part", %{"linked" => %{"of_widget" => "W-1"}}}
           ]

    %{
      back: "/k/widget",
      blocks: [%{"type" => "item", "props" => item}, %{"type" => "list", "props" => list}]
    } =
      Pages.render({:item, "widget", "W-1"}, @d, [answer, parts])

    assert item["title"] == "Widget W-1: One"

    assert Enum.map(item["fields"], &{&1["label"], &1["value"]}) == [
             {"Id", "W-1"},
             {"Title", "One"},
             {"Shade", "Light"},
             {"Done", "no"},
             {"Notes", "—"}
           ]

    assert list["title"] == "Parts"
    assert [%{"label" => "Wheel", "to" => "/k/part/P-1"}] = list["rows"]

    assert [%{"label" => "Add part", "key" => "a", "to" => "/k/part/new/of_widget/W-1"}] =
             list["actions"]

    %{blocks: [_, %{"props" => none}]} =
      Pages.render({:item, "widget", "W-1"}, @d, [answer, %{"facts" => []}])

    assert none["empty"] == "No parts yet. Press a to add one."
  end

  test "a fact that points at a parent names it, and goes back and away to it" do
    part = %{
      "fact" => %{
        "key" => "P-1",
        "values" => %{"title" => "Wheel"},
        "links" => %{"of_widget" => ["W-1"]},
        "version" => "v1"
      }
    }

    %{back: "/k/widget/W-1", blocks: [%{"props" => item}]} =
      Pages.render({:item, "part", "P-1"}, @d, [part])

    assert {"Of widget", "W-1"} in Enum.map(item["fields"], &{&1["label"], &1["value"]})
    assert Pages.after_delete(@d, "part", part) == {:item, "widget", "W-1"}
    assert Pages.after_delete(@d, "widget", %{"fact" => fact("W-1", %{})}) == {:list, "widget"}
  end

  test "a form to add a fact under its parent" do
    route = {:new, "part", {"of_widget", "W-1"}}
    assert Pages.route("/k/part/new/of_widget/W-1") == route
    %{back: "/k/widget/W-1", blocks: [%{"props" => form}]} = Pages.render(route, @d, [])
    assert form["title"] == "New part in W-1"
    assert form["submit_to"] == "/k/part/new/of_widget/W-1"
    assert form["cancel_to"] == "/k/widget/W-1"
  end

  test "a hint of a child kind refreshes its parent's page" do
    assert Pages.shows?({:item, "widget", "W-1"}, @d, "part")
    assert Pages.shows?({:item, "widget", "W-1"}, @d, "widget")
    refute Pages.shows?({:list, "widget"}, @d, "part")
    refute Pages.shows?({:item, "part", "P-1"}, @d, "gadget")
  end

  test "a create form has an id input and an input per property, typed by the description" do
    %{blocks: [%{"type" => "form", "props" => form}]} = Pages.render({:new, "widget"}, @d, [])
    inputs = Map.new(form["inputs"], &{&1["name"], &1})

    assert inputs["_key"]["hint"] == "starts with W-"
    assert inputs["title"]["required"] == true

    assert %{
             "kind" => "choice",
             "choices" => [%{"value" => ""}, %{"value" => "light", "label" => "Light"}, _]
           } = inputs["shade"]

    assert %{"kind" => "boolean", "value" => "false"} = inputs["done"]
    assert %{"kind" => "text", "hint" => "Free text"} = inputs["notes"]
    assert form["submit_to"] == "/k/widget/new"
  end

  test "a form shown again keeps what was typed and shows why it was refused" do
    page =
      Pages.render({:new, "widget"}, @d, [], %{
        values: %{"_key" => "W-9", "title" => ""},
        errors: ["title is required"]
      })

    %{blocks: [%{"props" => form}]} = page
    assert form["errors"] == ["title is required"]
    assert Enum.find(form["inputs"], &(&1["name"] == "_key"))["value"] == "W-9"
  end

  test "deleting asks first, and is refused while facts still hang under it" do
    free = %{"fact" => fact("W-1", %{"title" => "One"}), "incoming" => %{"of_widget" => []}}
    %{blocks: [%{"props" => confirm}]} = Pages.render({:delete, "widget", "W-1"}, @d, [free])
    assert confirm["confirm_to"] == "/k/widget/W-1/delete"

    held = %{
      "fact" => fact("W-1", %{"title" => "One"}),
      "incoming" => %{"of_widget" => ["P-1", "P-2"]}
    }

    %{blocks: [%{"props" => refusal}]} = Pages.render({:delete, "widget", "W-1"}, @d, [held])
    refute Map.has_key?(refusal, "confirm_to")
    assert refusal["text"] =~ "still has 2 parts"

    one = %{"fact" => fact("W-1", %{"title" => "One"}), "incoming" => %{"of_widget" => ["P-1"]}}
    %{blocks: [%{"props" => refusal}]} = Pages.render({:delete, "widget", "W-1"}, @d, [one])
    assert refusal["text"] =~ "still has 1 part."
  end

  test "form text becomes the described types" do
    spec = @d["entities"]["widget"]

    assert Pages.values_for(spec, %{
             "_key" => "W-1",
             "title" => "x",
             "done" => "true",
             "shade" => ""
           }) ==
             %{"title" => "x", "done" => true, "shade" => ""}
  end

  test "a page about a kind rela does not describe says so" do
    assert %{blocks: [%{"type" => "confirm"}]} =
             Pages.render({:list, "gadget"}, @d, [%{"facts" => []}])
  end
end
