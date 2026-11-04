defmodule AtlasPlan.ScenesTest do
  use ExUnit.Case, async: true

  alias AtlasPlan.Scenes

  @fixture Path.expand("../../../e2e/fixtures/scenes.md", __DIR__)

  test "scenes, use cases (table and prose) and issues, with full codes and parents" do
    plan = @fixture |> File.read!() |> Scenes.parse()

    assert Enum.map(plan.scenes, &{&1.code, &1.title}) == [
             {"SC-Atlas-01", "A loaded scene"},
             {"SC-Atlas-02", "A second loaded scene"}
           ]

    assert Enum.map(plan.use_cases, &{&1.code, &1.parent, &1.title}) == [
             {"UC-Atlas-01", "SC-Atlas-01", "A loaded use case"},
             {"UC-Atlas-02", "SC-Atlas-02", "A use case in prose"}
           ]

    assert [issue] = plan.issues
    assert {issue.code, issue.parent} == {"IS-Atlas-01", "UC-Atlas-01"}
    assert issue.title == "A loaded issue: it names SC-Atlas-02 and UC-02, which the loader maps"
  end

  test "a scene's description: its sections, without its tables; ### becomes ##" do
    [scene, second] = (@fixture |> File.read!() |> Scenes.parse()).scenes
    assert scene.description =~ "- Purpose: loaded by the end-to-end test.\n\n## User story\n\nAs"
    refute scene.description =~ "| Code |"
    refute scene.description =~ "This introduction"
    # A draft scene keeps its prose about use cases; the use case is made from it too.
    assert second.description =~ "## Use cases (draft)"
  end

  test "use cases in prose: a code in parentheses is a reference, not a use case" do
    text = """
    ## SC-Atlas-04: Draft

    ### Use cases (draft)

    UC-Atlas-16 Expose actions as tools (the same protocol). UC-Atlas-17 Ask and see the plan. Its first case (3 Nov, UC-Atlas-01 in test: "quoted."): more. UC-Atlas-18 Run, follow and stop the steps. Open point: which agent.
    """

    assert Enum.map(Scenes.parse(text).use_cases, &{&1.code, &1.title, &1.description}) == [
             {"UC-Atlas-16", "Expose actions as tools", "The same protocol."},
             {"UC-Atlas-17", "Ask and see the plan",
              "Its first case (3 Nov, UC-Atlas-01 in test: \"quoted.\"): more."},
             {"UC-Atlas-18", "Run, follow and stop the steps", ""}
           ]
  end

  test "an issue for several use cases hangs under the first; for all, under the scene's first" do
    text = """
    ## SC-Atlas-02: Two

    ### Use cases

    | Code | Use case | Melle can test |
    |---|---|---|
    | UC-Atlas-06 | Six | it |
    | UC-Atlas-07 | Seven | it |

    ### Issues

    | Code | Use case | Issue |
    |---|---|---|
    | IS-23 | UC-07, 10 | Failure actions. |
    | IS-24 | all | Scene test. |
    """

    [several, all] = Scenes.parse(text).issues
    assert {several.parent, several.also} == {"UC-Atlas-07", ["UC-Atlas-10"]}
    assert several.description =~ "Also for UC-Atlas-10."
    assert all.parent == "UC-Atlas-06"
    assert all.description =~ "For all use cases of SC-Atlas-02."
  end

  test "codes in text follow a mapping, short or full" do
    mapping = %{"SC-Atlas-01" => "SC-Atlas-02", "IS-Atlas-12" => "IS-Atlas-13"}
    rewrite = &Scenes.rewrite(&1, fn code -> Map.get(mapping, code, code) end)

    assert rewrite.("see SC-Atlas-01, IS-12 and UC-03") ==
             "see SC-Atlas-02, IS-Atlas-13 and UC-Atlas-03"
  end

  test "an issue's title: the first clause, cut at a comma when long" do
    assert Scenes.title("The Bus: messages carry an envelope (id, environment); it routes.") ==
             "The Bus: messages carry an envelope"

    long =
      "Scene test: an automated run of steps 1–6 in the test environment, plus a short guide for Melle to walk through it."

    assert Scenes.title(long) ==
             "Scene test: an automated run of steps 1–6 in the test environment"
  end
end
