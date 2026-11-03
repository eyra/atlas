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
      blocks: [
        %{"id" => "item", "type" => "item", "props" => item},
        %{"id" => "list:of_widget", "type" => "list", "props" => list}
      ],
      markup: markup
    } =
      Pages.render({:item, "widget", "W-1"}, @d, [answer, parts])

    # The fact in a border, the related list in a section that carries its title.
    assert [
             %{"kind" => "border", "start" => "item", "end" => "item", "props" => %{}},
             %{
               "kind" => "section",
               "start" => "list:of_widget",
               "end" => "list:of_widget",
               "props" => %{"title" => "Parts"}
             }
           ] = markup

    assert item["title"] == "Widget W-1: One"

    assert Enum.map(item["fields"], &{&1["label"], &1["value"]}) == [
             {"Id", "W-1"},
             {"Title", "One"},
             {"Shade", "Light"},
             {"Done", "no"},
             {"Notes", "—"}
           ]

    refute Map.has_key?(list, "title")
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

  test "a client that knows only the parent's key: _parent becomes the kind's parent relation" do
    route = Pages.route("/k/part/new/_parent/W-1")
    assert Pages.resolve(route, @d) == {:new, "part", {"of_widget", "W-1"}}

    assert Pages.resolve(Pages.route("/k/tag/new/_parent/P-1"), @d) ==
             {:new, "tag", {"on_part", "P-1"}}

    # A top kind belongs to no parent.
    assert Pages.resolve(Pages.route("/k/widget/new/_parent/W-1"), @d) == :unknown
    assert Pages.resolve({:list, "part"}, @d) == {:list, "part"}
  end

  test "a client that knows only a key: _ becomes the kind with that id prefix" do
    prefix = fn kind -> Pages.create_rule(@d["entities"][kind]).prefix end
    part = prefix.("part") <> "07"
    assert Pages.resolve(Pages.route("/k/_/#{part}"), @d) == {:item, "part", part}
    assert Pages.resolve(Pages.route("/k/_/#{part}/edit"), @d) == {:edit, "part", part}
    assert Pages.resolve(Pages.route("/k/_/#{part}/delete"), @d) == {:delete, "part", part}
    assert Pages.resolve(Pages.route("/k/_/nothing-1"), @d) == :unknown
  end

  test "the kinds page: per kind what a create asks, its id, its parent and its fields" do
    assert Pages.route("/_kinds") == :kinds
    assert Pages.path(:kinds) == "/_kinds"
    %{title: "Kinds", blocks: blocks} = Pages.render(:kinds, @d, [])
    items = for %{"type" => "item", "props" => props} <- blocks, do: props

    kinds =
      for item <- items,
          do: Enum.find_value(item["fields"], &(&1["label"] == "Kind" && &1["value"]))

    assert kinds == @d["entities"] |> Map.keys() |> Enum.sort()

    part = Enum.find(items, &(&1["title"] =~ "(part)"))
    fields = Map.new(part["fields"], &{&1["label"], &1["value"]})
    assert fields["Belongs under"] == "widget"
    assert fields["Has under it"] == "tag"
    assert fields["Id"] =~ "P-"
    assert fields["Fields"] =~ "title: text; required"

    widget = Enum.find(items, &(&1["title"] =~ "(widget)"))

    assert Enum.find_value(widget["fields"], &(&1["label"] == "Belongs under" && &1["value"])) ==
             "nothing; a top kind"
  end

  test "a hint of a child kind refreshes its parent's page" do
    assert Pages.shows?({:item, "widget", "W-1"}, @d, "part")
    assert Pages.shows?({:item, "widget", "W-1"}, @d, "widget")
    refute Pages.shows?({:list, "widget"}, @d, "part")
    refute Pages.shows?({:item, "part", "P-1"}, @d, "gadget")
  end

  test "a create form asks only what the kind's create rule asks; no id" do
    %{blocks: [%{"type" => "form", "props" => form}]} = Pages.render({:new, "widget"}, @d, [])
    assert Enum.map(form["inputs"], & &1["name"]) == ["title", "notes"]
    assert %{"required" => true} = hd(form["inputs"])
    # The description marks notes as text of several lines.
    assert Enum.map(form["inputs"], & &1["kind"]) == ["text", "multiline"]
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

  test "text of several lines keeps its line breaks, on the page and in a change form" do
    notes = "## Why\n\nBecause.\n\n- one\n- two"
    answer = %{"fact" => fact("W-01", %{"title" => "One", "notes" => notes})}

    %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "widget", "W-01"}, @d, [answer])
    assert Enum.find(item["fields"], &(&1["label"] == "Notes"))["value"] == notes

    %{blocks: [%{"props" => form}]} = Pages.render({:edit, "widget", "W-01"}, @d, [answer])

    assert %{"kind" => "multiline", "value" => ^notes} =
             Enum.find(form["inputs"], &(&1["name"] == "notes"))

    assert Pages.values_for(@d["entities"]["widget"], %{"notes" => notes}) == %{"notes" => notes}
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

  test "a primary a connector fills names the fact once filled; until then its id's source" do
    d = put_in(@d, ["entities", "tag", "primary"], "note")

    tags = %{
      "facts" => [
        fact("T-a-1", %{"name" => "#a/1"}),
        fact("T-b-2", %{"name" => "#b/2", "note" => "Two"})
      ]
    }

    %{blocks: [%{"props" => list}]} = Pages.render({:list, "tag"}, d, [tags])
    assert [%{"label" => "#a/1"}, %{"label" => "Two"}] = list["rows"]
  end

  test "a copy of an outside fact says when it was last read, and why a read failed" do
    last_read = fn copy ->
      answer = %{"fact" => fact("T-a-1", %{"name" => "#a/1", "note" => "x"}), "copy" => copy}
      %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "tag", "T-a-1"}, @d, [answer])
      Enum.find_value(item["fields"], &(&1["label"] == "Last read" && &1["value"]))
    end

    refute last_read.(nil)

    assert last_read.(%{"source" => "Outside", "read_at" => "2026-11-03T14:05:09Z"}) ==
             "2026-11-03 14:05 UTC from Outside"

    assert last_read.(%{
             "source" => "Outside",
             "read_at" => "2026-11-03T14:05:09Z",
             "failed_at" => "2026-11-03T14:10:00Z",
             "failure" => "it answered 503"
           }) ==
             "2026-11-03 14:05 UTC from Outside; the read at 2026-11-03 14:10 UTC failed: " <>
               "it answered 503; it is tried again"

    assert last_read.(%{
             "source" => "Outside",
             "read_at" => nil,
             "failed_at" => "2026-11-03T14:10:00Z",
             "failure" => "it answered 404"
           }) =~ "never from Outside; the read at 2026-11-03 14:10 UTC failed"
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
    assert refusal["text"] =~ "still has 2 parts. Remove them first"

    one = %{"fact" => fact("W-1", %{"title" => "One"}), "incoming" => %{"of_widget" => ["P-1"]}}
    %{blocks: [%{"props" => refusal}]} = Pages.render({:delete, "widget", "W-1"}, @d, [one])
    assert refusal["text"] =~ "still has 1 part. Remove it first"
    assert refusal["text"] =~ "never deletes it along with its parent"
  end

  test "a kind whose id is made from a property: the key is made, never typed or changed" do
    tag = @d["entities"]["tag"]
    assert Pages.key_for(tag, %{"name" => " #a.b/12 "}) == {:ok, "T-a_b-12"}
    assert Pages.key_for(tag, %{"name" => "a.b"}) == {:error, "name must look like #word/1"}
    assert Pages.id_property(tag) == "name"
    assert Pages.id_property(@d["entities"]["widget"]) == nil

    %{blocks: [%{"props" => form}]} = Pages.render({:new, "tag", {"on_part", "P-1"}}, @d, [])
    assert Enum.map(form["inputs"], &{&1["name"], &1["kind"]}) == [{"name", "text"}]

    stored = %{"fact" => %{"key" => "T-a-1", "values" => %{"name" => "#a/1"}, "version" => "v1"}}

    # Shown, never changed: the id and the property it is made from.
    %{blocks: [%{"props" => edit}]} = Pages.render({:edit, "tag", "T-a-1"}, @d, [stored])

    assert Enum.map(edit["inputs"], &{&1["name"], &1["kind"], &1["value"]}) == [
             {"_key", "readonly", "T-a-1"},
             {"name", "readonly", "#a/1"}
           ]

    # Labelled by that property; nothing a person may change, so no Change action.
    %{blocks: [%{"props" => item} | _]} = Pages.render({:item, "tag", "T-a-1"}, @d, [stored])
    assert item["title"] == "Tag T-a-1: #a/1"
    assert Enum.map(item["actions"], & &1["key"]) == ["d"]
  end

  test "a fact with a web address can be opened in a browser, on its page and on its row" do
    site = "https://example.org/tags/1"
    tag = fact("T-a-1", %{"name" => "#a/1", "site" => site})
    link = [%{"label" => "Open in browser", "key" => "o", "url" => site}]

    %{blocks: [%{"props" => item}]} =
      Pages.render({:item, "tag", "T-a-1"}, @d, [%{"fact" => tag}])

    assert item["links"] == link

    part = %{
      "fact" => fact("P-1", %{"title" => "Wheel"}),
      "incoming" => %{"on_part" => ["T-a-1"]}
    }

    page = Pages.render({:item, "part", "P-1"}, @d, [part, %{"facts" => [tag]}])
    [%{"props" => part_item}, %{"props" => tags}] = page.blocks
    refute Map.has_key?(part_item, "links")
    assert [%{"links" => ^link}] = tags["rows"]

    # Nothing to open without a value, nor anything but http and https.
    for values <- [%{"name" => "#a/1"}, %{"name" => "#a/1", "site" => "file:///etc/passwd"}] do
      %{blocks: [%{"props" => item}]} =
        Pages.render({:item, "tag", "T-a-1"}, @d, [%{"fact" => fact("T-a-1", values)}])

      refute Map.has_key?(item, "links")
    end
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
