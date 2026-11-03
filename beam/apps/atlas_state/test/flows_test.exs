defmodule AtlasState.FlowsTest do
  use ExUnit.Case, async: true

  alias AtlasState.Flows

  @root Path.expand("../../../..", __DIR__)

  # Made-up kinds: a box holds crates; a box is signed off.
  defp description(states, extra \\ %{}) do
    %{
      "entities" => %{
        "box" => %{"properties" => %{"todo" => %{"type" => "string"}}},
        "crate" => %{"properties" => %{}}
      },
      "relations" => %{"signed_by" => %{"from" => ["box"], "to" => ["clerk"]}},
      "flows" => %{
        "sign" => Map.merge(%{"kinds" => ["box"], "field" => "todo", "states" => states}, extra)
      }
    }
  end

  @sound [
    %{"name" => "done", "when" => %{"completed" => true}, "done" => true},
    %{
      "name" => "check",
      "when" => %{"progress" => "check"},
      "owner" => "ada",
      "next" => ["done"]
    },
    %{"name" => "work", "owner" => "bob", "next" => ["check"]}
  ]

  test "a sound definition has no problems" do
    assert Flows.check(description(@sound)) == %{"sign" => []}
  end

  test "every state that is not done has an owner and a way out to a state that exists" do
    states = [
      hd(@sound),
      %{"name" => "check", "when" => %{"progress" => "check"}, "next" => ["nowhere"]},
      %{"name" => "work", "owner" => "bob"}
    ]

    assert %{"sign" => problems} = Flows.check(description(states))
    assert "check has no owner" in problems
    assert ~s(check: its next "nowhere" is no state) in problems
    assert "work has no way out (next)" in problems
  end

  test "every state reaches done; there is a done state; the last holds when no other does" do
    loop = [
      hd(@sound),
      %{"name" => "a", "when" => %{"progress" => "x"}, "owner" => "ada", "next" => ["b"]},
      %{"name" => "b", "owner" => "bob", "next" => ["a"]}
    ]

    assert %{"sign" => problems} = Flows.check(description(loop))
    assert "a never reaches done" in problems
    assert "b never reaches done" in problems

    no_done = [
      %{"name" => "work", "when" => %{"progress" => "x"}, "owner" => "bob", "next" => ["work"]}
    ]

    assert %{"sign" => problems} = Flows.check(description(no_done))
    assert "has no done state" in problems
    assert "the last state, work, must hold when no other does (no when)" in problems
  end

  test "what a definition names must exist" do
    assert %{"sign" => problems} =
             Flows.check(
               description(@sound, %{
                 "kinds" => ["box", "crate", "lid"],
                 "owner_relation" => "signed_by"
               })
             )

    assert "crate has no todo to write what is expected" in problems
    assert "lid is not described" in problems
    assert "signed_by does not start at crate" in problems

    odd = [%{hd(@sound) | "when" => %{"colour" => "red"}} | tl(@sound)]
    assert %{"sign" => ["done: when knows no colour"]} = Flows.check(description(odd))
  end

  test "no state depends on what Flow writes: it passes over the hints of its own writes" do
    states = [
      hd(@sound),
      %{
        "name" => "check",
        "when" => %{"reopened" => "signed_by"},
        "owner" => "ada",
        "next" => ["done"]
      },
      %{"name" => "work", "owner" => "bob", "next" => ["check"]}
    ]

    description =
      description(states, %{"owner_relation" => "signed_by"})
      |> put_in(["entities", "box", "progress"], %{"own" => "todo"})

    assert %{"sign" => problems} = Flows.check(description)
    assert "check depends on signed_by, which Flow writes" in problems
    assert "box's progress or completion depends on todo, which Flow writes" in problems
  end

  test "the definitions in rela/atlas.json are sound" do
    extra = @root |> Path.join("rela/atlas.json") |> File.read!() |> JSON.decode!()
    assert map_size(extra["flows"]) > 0

    assert Enum.all?(Flows.check(extra), fn {_name, problems} -> problems == [] end),
           inspect(Flows.check(extra))
  end
end
