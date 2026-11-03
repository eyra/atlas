# The end-to-end test's stand-in for the planning agent (agent.planner in the instance's
# settings), so CI needs no model. It speaks the planner's protocol (AtlasAgent.Planner):
# the input as JSON on stdin, a plan as JSON on stdout. Like a real planner it knows only
# the page it is given and the tools; it reads nothing else.
#
# - "propose use cases ..." on an item whose description has lines "- <title>": one put
#   per line, of the kind that goes in the page's kind.
# - "rename to <title>": one set of the page's item.
# - "colour it <x>": a set of a field nobody has, which the plan check must catch.
# - anything else: no steps.

input = IO.read(:stdio, :eof) |> JSON.decode!()
request = input["request"]
page = input["page"]
[_, "k", kind, key | _] = String.split(page["path"], "/")

item = Enum.find_value(page["blocks"], &(&1["type"] == "item" && &1["props"]))
fields = if item, do: item["fields"], else: []
description = Enum.find_value(fields, "", &(&1["label"] == "Description" && &1["value"]))

plan =
  cond do
    request =~ ~r/propose use cases/i ->
      tool = Enum.find(input["tools"], &(&1["tool"] == "put" and &1["in"] == kind))

      steps =
        for "- " <> title <- String.split(description, "\n") do
          %{
            "tool" => "put",
            "kind" => tool["kind"],
            "in" => key,
            "values" => %{"title" => title, "description" => "Proposed from #{key}."},
            "why" => "The description of #{key} names it."
          }
        end

      %{"summary" => "#{length(steps)} use cases, one per line of the description.", "steps" => steps}

    match = Regex.run(~r/rename to (.+)$/i, request) ->
      [_, title] = match

      %{
        "summary" => "Renames #{key}.",
        "steps" => [%{"tool" => "set", "key" => key, "values" => %{"title" => title}, "why" => "Asked."}]
      }

    match = Regex.run(~r/colour it (.+)$/i, request) ->
      [_, colour] = match

      %{
        "summary" => "Colours #{key}.",
        "steps" => [%{"tool" => "set", "key" => key, "values" => %{"colour" => colour}, "why" => "Asked."}]
      }

    true ->
      %{"summary" => "Nothing to do for this request.", "steps" => []}
  end

IO.puts(JSON.encode!(plan))
