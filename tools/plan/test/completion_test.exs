defmodule AtlasPlan.CompletionTest do
  use ExUnit.Case, async: true

  alias AtlasPlan.Completion

  defp fact(id, properties, relations \\ %{}),
    do: %{"id" => id, "properties" => properties, "relations" => relations}

  defp old,
    do: %{
      "scenes" => [fact("SC-Atlas-01", %{"completed" => false})],
      "use_cases" => [
        fact("UC-Atlas-01", %{"completed" => true}),
        fact("UC-Atlas-02", %{"completed" => true}, %{"accepted_by" => ["melle"]}),
        fact("UC-Atlas-03", %{})
      ],
      "issues" => [
        fact("IS-Atlas-01", %{"completed" => true, "stage" => "testing"}),
        fact("IS-Atlas-02", %{"completed" => true, "stage" => "testing"}),
        fact("IS-Atlas-03", %{"completed" => true, "stage" => "development"}),
        fact("IS-Atlas-04", %{"stage" => "specification"}),
        fact("IS-Atlas-05", %{"completed" => true}, %{"done_in" => ["PR-eyra-atlas-1"]})
      ],
      "pull_requests" => [
        fact(
          "PR-eyra-atlas-1",
          %{"url" => "https://github.com/eyra/atlas/pull/1", "state" => "merged"},
          %{
            "in_issue" => ["IS-Atlas-01"]
          }
        )
      ],
      "people" => []
    }

  test "the steps: the person, acceptances, stages, and history links from the file" do
    done_in = %{"IS-Atlas-02" => "https://github.com/eyra/atlas/pull/1"}

    assert {steps, unmapped} = Completion.steps(old(), done_in)

    assert steps == [
             {:person, "Melle"},
             {:accept, "UC-Atlas-01", "melle"},
             {:stage, "IS-Atlas-01", "development"},
             {:stage, "IS-Atlas-02", "development"},
             {:done_in, "IS-Atlas-02", "PR-eyra-atlas-1"}
           ]

    # IS-Atlas-01 has its own merged pull request; IS-Atlas-03 has none, nor one in the file.
    assert unmapped == ["IS-Atlas-03"]
  end

  test "a second run finds nothing left to do" do
    done = %{
      old()
      | "people" => [fact("melle", %{"name" => "Melle"})],
        "use_cases" => [
          fact("UC-Atlas-01", %{"completed" => true}, %{"accepted_by" => ["melle"]})
        ],
        "issues" => [
          fact("IS-Atlas-02", %{"completed" => true, "stage" => "development"}, %{
            "done_in" => ["PR-eyra-atlas-1"]
          })
        ]
    }

    assert {[], []} = Completion.steps(done, %{})
  end
end
