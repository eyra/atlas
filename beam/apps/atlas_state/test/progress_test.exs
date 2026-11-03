defmodule AtlasState.ProgressTest do
  use ExUnit.Case, async: true

  alias AtlasState.Progress

  # Made-up kinds, two levels: a box holds crates, a crate holds jars. A jar says how far it
  # is in `phase`; a crate and a box in `group` while nothing is under them.
  @description %{
    "progress" => %{
      "order" => ["draft", "agreed", "packing", "sealed"],
      "done" => "shipped",
      "done_label" => "Shipped"
    },
    "entities" => %{
      "box" => %{
        "plural" => "boxes",
        "progress" => %{"over" => "in_box", "own" => "group"},
        "properties" => %{"group" => %{"labels" => %{"draft" => "Draft", "agreed" => "Agreed"}}}
      },
      "crate" => %{
        "plural" => "crates",
        "progress" => %{"over" => "in_crate", "field" => "phase", "own" => "group"},
        "properties" => %{"group" => %{"labels" => %{"draft" => "Draft", "agreed" => "Agreed"}}}
      },
      "jar" => %{
        "plural" => "jars",
        "properties" => %{
          "phase" => %{"labels" => %{"packing" => "Packing", "sealed" => "Sealed"}}
        }
      }
    },
    "relations" => %{
      "in_box" => %{"from" => ["crate"], "to" => ["box"]},
      "in_crate" => %{"from" => ["jar"], "to" => ["crate"]}
    }
  }

  defp fact(key, properties, links \\ %{}),
    do: %{key: key, properties: properties, links: links, version: nil}

  defp progress(kind, facts, lists) do
    {:ok, annotated} =
      Progress.annotate(@description, kind, facts, fn of -> {:ok, lists[of] || []} end)

    Enum.map(annotated, & &1.progress)
  end

  defp jar(key, crate, phase, shipped \\ false),
    do: fact(key, %{"phase" => phase, "shipped" => shipped}, %{"in_crate" => [crate]})

  test "the least far child wins, with how many are that far, of all of them" do
    jars = [
      jar("J-1", "C-1", "sealed"),
      jar("J-2", "C-1", "packing"),
      jar("J-3", "C-1", "sealed")
    ]

    assert [%{"value" => "packing", "label" => "Packing", "count" => 1, "of" => 3}] =
             progress("crate", [fact("C-1", %{"group" => "agreed"})], %{"jar" => jars})

    jars = [jar("J-1", "C-1", "sealed"), jar("J-2", "C-1", "sealed")]

    assert [%{"value" => "sealed", "count" => 2, "of" => 2}] =
             progress("crate", [fact("C-1", %{"group" => "agreed"})], %{"jar" => jars})
  end

  test "done when every child is; a done child counts as further than any value" do
    jars = [jar("J-1", "C-1", "sealed", true), jar("J-2", "C-1", "packing", true)]

    assert [%{"done" => true, "label" => "Shipped", "count" => 2, "of" => 2}] =
             progress("crate", [fact("C-1", %{})], %{"jar" => jars})

    jars = [jar("J-1", "C-1", "sealed", true), jar("J-2", "C-1", "packing")]

    assert [%{"value" => "packing", "count" => 1, "of" => 2}] =
             progress("crate", [fact("C-1", %{})], %{"jar" => jars})
  end

  test "without children: its own value, without a count; or nothing" do
    assert [%{"value" => "agreed", "label" => "Agreed"} = own, nil, %{"done" => true}] =
             progress(
               "crate",
               [
                 fact("C-1", %{"group" => "agreed"}),
                 fact("C-2", %{}),
                 fact("C-3", %{"shipped" => true})
               ],
               %{"jar" => [jar("J-1", "C-9", "sealed")]}
             )

    refute Map.has_key?(own, "count")
  end

  test "a parent rolls up its children's progress, which rolls up theirs" do
    crates = [
      fact("C-1", %{"group" => "agreed"}, %{"in_box" => ["B-1"]}),
      fact("C-2", %{"group" => "draft"}, %{"in_box" => ["B-1"]}),
      fact("C-3", %{"group" => "draft"}, %{"in_box" => ["B-2"]})
    ]

    jars = [jar("J-1", "C-1", "sealed"), jar("J-2", "C-3", "packing")]
    boxes = [fact("B-1", %{}), fact("B-2", %{"group" => "draft"})]

    # C-2 has no jars, so it is only as far as its own group: draft, before any phase.
    assert [
             %{"value" => "draft", "label" => "Draft", "count" => 1, "of" => 2},
             %{"value" => "packing", "count" => 1, "of" => 1}
           ] = progress("box", boxes, %{"crate" => crates, "jar" => jars})
  end

  test "a kind without a rule is left as it is, and nothing is read" do
    facts = [fact("J-1", %{"phase" => "sealed"})]
    assert {:ok, ^facts} = Progress.annotate(@description, "jar", facts, fn _ -> raise "read" end)
  end

  test "when the children cannot be read, neither can the progress" do
    assert {:error, :unavailable} =
             Progress.annotate(@description, "crate", [fact("C-1", %{})], fn _ ->
               {:error, :unavailable}
             end)
  end
end
