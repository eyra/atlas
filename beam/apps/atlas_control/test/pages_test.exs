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

  test "an item shows every described property and how many facts hang under it" do
    answer = %{
      "fact" => fact("W-1", %{"title" => "One", "shade" => "light"}),
      "incoming" => %{"of_widget" => ["P-1", "P-2"]}
    }

    %{blocks: [%{"type" => "item", "props" => item}]} =
      Pages.render({:item, "widget", "W-1"}, @d, [answer])

    assert item["title"] == "Widget W-1: One"

    assert Enum.map(item["fields"], &{&1["label"], &1["value"]}) == [
             {"Id", "W-1"},
             {"Title", "One"},
             {"Shade", "Light"},
             {"Done", "no"},
             {"Notes", "—"},
             {"Parts", "2"}
           ]
  end

  test "a create form asks only what the kind's create rule asks; no id" do
    %{blocks: [%{"type" => "form", "props" => form}]} = Pages.render({:new, "widget"}, @d, [])
    assert Enum.map(form["inputs"], & &1["name"]) == ["title", "notes"]
    assert %{"required" => true} = hd(form["inputs"])
    assert form["submit_to"] == "/k/widget/new"

    # Without a rule: every field a person may set, still no id.
    %{blocks: [%{"props" => plain}]} = Pages.render({:new, "part"}, @d, [])
    assert Enum.map(plain["inputs"], & &1["name"]) == ["title"]
  end

  test "a form shown again keeps what was typed and shows why it was refused" do
    page = Pages.render({:new, "widget"}, @d, [], %{values: %{"title" => "Mine"}, errors: ["no"]})
    %{blocks: [%{"props" => form}]} = page
    assert form["errors"] == ["no"]
    assert Enum.find(form["inputs"], &(&1["name"] == "title"))["value"] == "Mine"
  end

  test "a change form shows the id read-only and every field a person may set" do
    answer = %{"fact" => fact("W-01", %{"title" => "One", "ext_ref" => "X-9"})}
    %{blocks: [%{"props" => form}]} = Pages.render({:edit, "widget", "W-01"}, @d, [answer])
    inputs = Enum.map(form["inputs"], &{&1["name"], &1["kind"]})
    assert hd(inputs) == {"_key", "readonly"}
    assert Enum.map(inputs, &elem(&1, 0)) == ["_key", "title", "shade", "done", "notes"]

    assert %{
             "kind" => "choice",
             "choices" => [%{"value" => ""}, %{"value" => "light", "label" => "Light"}, _]
           } =
             Enum.find(form["inputs"], &(&1["name"] == "shade"))
  end

  test "a field only a connector fills shows on the page only when it has a value" do
    labels = fn values ->
      %{blocks: [%{"props" => item}]} =
        Pages.render({:item, "widget", "W-01"}, @d, [%{"fact" => fact("W-01", values)}])

      Enum.map(item["fields"], & &1["label"])
    end

    refute "Ext ref" in labels.(%{"title" => "One"})
    assert "Ext ref" in labels.(%{"title" => "One", "ext_ref" => "X-9"})
  end

  test "the next free key, and the values of a new fact" do
    spec = @d["entities"]["widget"]
    assert Pages.next_key(spec, []) == {"W-01", 1}
    assert Pages.next_key(spec, ["W-01", "W-07", "W-x", "Z-99"]) == {"W-08", 8}
    assert Pages.next_key(spec, ["W-01"], 4) == {"W-05", 5}

    assert Pages.create_values(spec, %{"title" => "One", "notes" => "", "shade" => "dark"}) ==
             %{"title" => "One", "notes" => "", "shade" => "light", "done" => false}
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
