defmodule AtlasPlan.OwnerTest do
  use ExUnit.Case, async: true

  alias AtlasPlan.Owner

  # rela's description and facts, as its API gives them.
  @schema %{
    "entities" => %{
      "scene" => %{"plural" => "scenes"},
      "issue" => %{"plural" => "issues"},
      "agent" => %{"plural" => "agents"}
    },
    "relations" => %{
      "assigned_to" => %{"from" => ["scene", "issue"], "to" => ["person", "agent"]}
    }
  }

  defp fact(id, relations \\ %{}), do: %{"id" => id, "relations" => relations}

  test "the coordinator first, then every fact without an owner, in key order" do
    facts = %{
      "scenes" => [fact("SC-Atlas-02"), fact("SC-Atlas-01")],
      "issues" => [fact("IS-Atlas-01", %{"assigned_to" => ["melle"]}), fact("IS-Atlas-02")],
      "agents" => []
    }

    assert Owner.steps(@schema, facts) == [
             {:agent, "Coordinator"},
             {:assign, "SC-Atlas-01", "coordinator"},
             {:assign, "SC-Atlas-02", "coordinator"},
             {:assign, "IS-Atlas-02", "coordinator"}
           ]

    assert Owner.plurals(@schema) == ["scenes", "issues"]

    assert Owner.line({:assign, "IS-Atlas-02", "coordinator"}) ==
             "assign   IS-Atlas-02  assigned_to coordinator"
  end

  test "a second run finds nothing left to do" do
    facts = %{
      "scenes" => [fact("SC-Atlas-01", %{"assigned_to" => ["coordinator"]})],
      "issues" => [],
      "agents" => [fact("coordinator")]
    }

    assert Owner.steps(@schema, facts) == []
  end
end
