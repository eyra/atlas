defmodule AtlasTui.AskTest do
  @moduledoc "`:` asks the agent; its plan shows over the page (UC-Atlas-17)."
  use ExUnit.Case, async: true

  alias AtlasTui.{Model, View}

  # A page, and what the agent sends, by hand; the kind is made up.
  @page %{
    "op" => "page",
    "path" => "/k/thing/T-1",
    "title" => "Thing T-1",
    "back" => "/k/thing",
    "reason" => "open",
    "blocks" => [
      %{
        "type" => "item",
        "props" => %{"title" => "Thing T-1: First", "fields" => [], "actions" => []}
      }
    ]
  }

  defp step(n, title, state \\ "proposed") do
    %{
      "n" => n,
      "label" => "New part in T-1",
      "state" => state,
      "why" => "Asked.",
      "inputs" => [
        %{"name" => "title", "label" => "Title", "kind" => "text", "value" => title},
        %{"name" => "notes", "label" => "Notes", "kind" => "multiline", "value" => "n#{n}"}
      ]
    }
  end

  defp plan(state, steps, extra \\ %{}) do
    props =
      Map.merge(
        %{"title" => "Proposed", "request" => "make parts", "state" => state, "steps" => steps},
        extra
      )

    %{"op" => "plan", "block" => %{"id" => "plan", "type" => "plan", "props" => props}}
  end

  defp model,
    do: "test" |> Model.new() |> Model.message(%{"op" => "welcome"}) |> Model.message(@page)

  defp press(model, keys) do
    Enum.reduce(keys, {model, []}, fn key, {m, effects} ->
      {m, more} = Model.key(m, key)
      {m, effects ++ more}
    end)
  end

  defp type(text), do: Enum.map(String.graphemes(text), &{:char, &1})
  defp screen(model), do: model |> View.render(100, 40, 5) |> View.plain()

  defp asked do
    {m, [{:agent, ask}]} = press(model(), [{:char, ":"}] ++ type("make parts") ++ [:enter])
    {m, ask}
  end

  test "`:` opens the request line; enter asks about the page, esc closes it" do
    {m, []} = press(model(), [{:char, ":"}] ++ type("make partz") ++ [:backspace, {:char, "s"}])
    assert screen(m) =~ " : make parts"
    assert screen(m) =~ "↵ ask the agent   esc close"

    {closed, []} = press(m, [:esc])
    assert closed.ask == nil
    refute screen(closed) =~ " : make parts"

    {m, ask} = asked()
    assert ask == %{"op" => "ask", "request" => "make parts", "on" => "/k/thing/T-1"}
    assert screen(m) =~ "Planning…"
    assert {%{plan: nil}, [{:agent, %{"op" => "cancel"}}]} = press(m, [:esc])
  end

  test "the help line offers `:`" do
    assert screen(model()) =~ ": ask"
  end

  test "the plan shows each step with its form's title and values" do
    {m, _} = asked()

    m =
      Model.agent(m, plan("proposed", [step(1, "One"), step(2, "Two")], %{"by" => "a stand-in"}))

    text = screen(m)
    assert text =~ "You asked       make parts"
    assert text =~ "By              a stand-in"
    assert text =~ "› [✓] 1. New part in T-1"
    assert text =~ "Title"
    assert text =~ "Two"
    assert text =~ "why: Asked."
    assert text =~ "space keep/drop   e edit   ↵ run the kept steps"
  end

  test "drop one, edit another, enter runs the kept ones with the edited values" do
    {m, _} = asked()
    m = Model.agent(m, plan("proposed", [step(1, "One"), step(2, "Two"), step(3, "Three")]))

    # Drop step 2; edit step 3's title in the step's form, keep it with ctrl-s.
    {m, []} = press(m, [:down, {:char, " "}, :down, {:char, "e"}])
    assert screen(m) =~ "Step 3: New part in T-1"
    assert screen(m) =~ "[ Keep ]"
    {m, []} = press(m, type("!") ++ [:ctrl_s])
    assert m.steps.editing == nil
    text = screen(m)
    assert text =~ "[ ] 2. New part in T-1"
    assert text =~ "Three!"

    {_, [{:agent, run}]} = press(m, [:enter])

    assert run == %{
             "op" => "run",
             "steps" => [
               %{"n" => 1, "values" => %{"title" => "One", "notes" => "n1"}},
               %{"n" => 3, "values" => %{"title" => "Three!", "notes" => "n3"}}
             ]
           }
  end

  test "esc in a step's form leaves its values as they were" do
    {m, _} = asked()
    m = Model.agent(m, plan("proposed", [step(1, "One")]))
    {m, []} = press(m, [{:char, "e"}] ++ type("xx") ++ [:esc])
    assert m.steps.editing == nil
    {_, [{:agent, %{"steps" => [%{"values" => %{"title" => "One"}}]}}]} = press(m, [:enter])
  end

  test "a step that cannot run is shown with why, and enter asks to drop it" do
    {m, _} = asked()
    blocked = Map.put(step(1, "One", "blocked"), "detail", "no field colour")
    m = Model.agent(m, plan("proposed", [blocked]))
    assert screen(m) =~ "[!] 1."
    assert screen(m) =~ "no field colour"
    {m, []} = press(m, [:enter])
    assert m.notice.text =~ "Step 1 cannot run"
    {m, []} = press(m, [{:char, " "}, :enter])
    assert m.notice.text =~ "Every step is dropped"
  end

  test "while it runs each step shows its state; esc asks the agent to stop" do
    {m, _} = asked()
    m = Model.agent(m, plan("proposed", [step(1, "One"), step(2, "Two")]))
    stored = Map.put(step(1, "One", "stored"), "detail", "Stored as T-7.")
    m = Model.agent(m, plan("running", [stored, step(2, "Two", "running")]))
    assert screen(m) =~ "Stored as T-7."
    assert screen(m) =~ "[…] 2."
    assert {_, [{:agent, %{"op" => "stop"}}]} = press(m, [:esc])

    done =
      Model.agent(
        m,
        plan("done", [stored, Map.put(step(2, "Two", "stored"), "detail", "Stored as T-8.")])
      )

    assert screen(done) =~ "↵ close"
    assert {%{plan: nil}, []} = press(done, [:enter])
  end

  test "`:` on a proposed plan changes the request; a plan for a cancelled ask is ignored" do
    {m, _} = asked()
    m = Model.agent(m, plan("proposed", [step(1, "One")]))
    {m, []} = press(m, [{:char, ":"}])
    assert m.ask == "make parts"

    {m, _} = press(model(), [{:char, ":"}] ++ type("x") ++ [:enter, :esc])
    assert Model.agent(m, plan("proposed", [step(1, "One")])).plan == nil
  end

  test "a plan after a refusal says what happened before" do
    {m, _} = asked()
    before = "Step 2 (New part in T-1) was refused: T-1 does not exist."
    m = Model.agent(m, plan("planning", [], %{"before" => before}))
    assert screen(m) =~ "Before          Step 2 (New part in T-1) was refused"
    m = Model.agent(m, plan("proposed", [step(1, "Three")], %{"before" => before}))
    assert screen(m) =~ "T-1 does not exist."
    assert {_, [{:agent, %{"op" => "run"}}]} = press(m, [:enter])
  end

  test "when the agent stops, a plan it was making says so" do
    {m, _} = asked()
    m = Model.agent_gone(m, "it exited with 1")
    assert m.plan.state == "failed"
    assert screen(m) =~ "The agent stopped"
  end
end
