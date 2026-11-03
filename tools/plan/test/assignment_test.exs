defmodule AtlasPlan.AssignmentTest do
  use ExUnit.Case, async: true

  alias AtlasPlan.Assignment

  defp fact(id, relations \\ %{}, properties \\ %{}),
    do: %{"id" => id, "relations" => relations, "properties" => properties}

  test "the kinds: those the association starts at, or on the old description assigned_to's" do
    old = %{"relations" => %{"assigned_to" => %{"from" => ["scene", "issue"]}}}

    new = %{
      "entities" => %{
        "scene" => %{"plural" => "scenes"},
        "assignment" => %{"plural" => "assignments"}
      },
      "relations" => %{
        "assigned_to" => %{"from" => ["assignment"]},
        "assignment" => %{"from" => ["scene"]}
      }
    }

    assert Assignment.kinds(old) == ["scene", "issue"]
    assert Assignment.kinds(new) == ["scene"]
    assert Assignment.plurals(new) == ["scenes", "assignments"]
    assert Assignment.key_of("UC-Atlas-01") == "AS-UC-Atlas-01"
  end

  test "each fact gets its Assignment, and its owner moves there with who set it, and why" do
    facts = [
      fact("SC-Atlas-02"),
      fact("SC-Atlas-01", %{"assigned_to" => ["coordinator"]})
    ]

    origins = %{
      "SC-Atlas-01" => %{
        "since" => "2026-11-03T17:00:00Z",
        "by" => "migration",
        "cause" => "owner introduced"
      }
    }

    assert [
             {:make, "SC-Atlas-01", "AS-SC-Atlas-01"},
             {:link, "SC-Atlas-01", "AS-SC-Atlas-01"},
             {:assign, "AS-SC-Atlas-01", "coordinator", cause},
             {:unlink, "SC-Atlas-01", "coordinator"},
             {:make, "SC-Atlas-02", "AS-SC-Atlas-02"},
             {:link, "SC-Atlas-02", "AS-SC-Atlas-02"}
           ] = Assignment.steps(facts, [], origins)

    assert cause ==
             "assignment introduced (IS-Atlas-78); moved from SC-Atlas-01, " <>
               "set 2026-11-03T17:00:00Z by migration: owner introduced"

    assert Assignment.cause("SC-Atlas-02", nil) =~ "did not say who set it"
  end

  test "a second run finds nothing left to do; an owner set on the Assignment meanwhile stays" do
    done = [fact("SC-Atlas-01", %{"assignment" => ["AS-SC-Atlas-01"]})]

    parts = [
      fact("AS-SC-Atlas-01", %{"assigned_to" => ["melle"]}, %{"of" => "SC-Atlas-01"})
    ]

    assert Assignment.steps(done, parts, %{}) == []

    # Still the old link on the fact, but someone set the Assignment's owner since.
    left = [fact("SC-Atlas-01", %{"assignment" => ["AS-SC-Atlas-01"], "assigned_to" => ["ann"]})]
    assert Assignment.steps(left, parts, %{}) == [{:unlink, "SC-Atlas-01", "ann"}]
  end
end
