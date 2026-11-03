defmodule AtlasState.Flows do
  @moduledoc """
  Checks the flow definitions in the description (`flows` in `rela/atlas.json`) before
  anyone runs them (architecture, rule 4): every state that is not done has an owner and
  a way out to a next state, every state can reach done, the last state holds when no
  other does, and what a definition names exists. State answers the problems with the
  description (`flow_problems`, per definition); Flow runs only a definition without any.
  Knows no kind by name.
  """

  @conditions ~w(completed progress reopened)

  @doc "The problems of every definition: `%{name => [problem]}` (empty lists when sound)."
  def check(description) do
    for {name, flow} <- description["flows"] || %{}, into: %{} do
      {name, if(is_map(flow), do: problems(description, flow), else: ["is not a definition"])}
    end
  end

  defp problems(description, flow) do
    states = Enum.filter(List.wrap(flow["states"]), &is_map/1)
    names = Enum.map(states, & &1["name"])
    by_name = Map.new(states, &{&1["name"], &1})

    kinds(description, flow) ++
      relation(description, flow) ++
      cond do
        states == [] ->
          ["has no states"]

        length(Enum.uniq(names)) != length(names) or Enum.any?(names, &(not is_binary(&1))) ->
          ["every state needs a name of its own"]

        true ->
          shape(states, by_name) ++ reach(states, by_name)
      end
  end

  defp kinds(description, flow) do
    kinds = List.wrap(flow["kinds"])
    field = flow["field"]

    cond do
      kinds == [] ->
        ["runs on no kind"]

      true ->
        for kind <- kinds,
            problem <-
              (cond do
                 not Map.has_key?(description["entities"] || %{}, kind) ->
                   ["#{kind} is not described"]

                 is_binary(field) and
                     get_in(description, ["entities", kind, "properties", field]) == nil ->
                   ["#{kind} has no #{field} to write what is expected"]

                 true ->
                   []
               end),
            do: problem
    end
  end

  defp relation(_description, %{"owner_relation" => nil}), do: []

  defp relation(description, %{"owner_relation" => relation} = flow) do
    case get_in(description, ["relations", relation]) do
      nil ->
        ["#{relation} is not described"]

      spec ->
        for kind <- List.wrap(flow["kinds"]),
            kind not in (spec["from"] || []),
            do: "#{relation} does not start at #{kind}"
    end
  end

  defp relation(_description, _flow), do: []

  defp shape(states, by_name) do
    last = List.last(states)

    fallback =
      if (last["when"] || %{}) == %{},
        do: [],
        else: ["the last state, #{last["name"]}, must hold when no other does (no when)"]

    done = if Enum.any?(states, &(&1["done"] == true)), do: [], else: ["has no done state"]

    each =
      Enum.flat_map(states, fn state ->
        name = state["name"]

        unknown =
          for {condition, _} <- state["when"] || %{},
              condition not in @conditions,
              do: "#{name}: when knows no #{condition}"

        unknown ++ open_problems(state, by_name)
      end)

    fallback ++ done ++ each
  end

  # A state that is not done needs an owner and a way out to states that exist.
  defp open_problems(%{"done" => true}, _by_name), do: []

  defp open_problems(state, by_name) do
    name = state["name"]

    owner =
      if is_binary(state["owner"]) and state["owner"] != "",
        do: [],
        else: ["#{name} has no owner"]

    next =
      case List.wrap(state["next"]) do
        [] ->
          ["#{name} has no way out (next)"]

        next ->
          for n <- next,
              not Map.has_key?(by_name, n),
              do: "#{name}: its next #{inspect(n)} is no state"
      end

    owner ++ next
  end

  # From every state, following next, some done state is reached.
  defp reach(states, by_name) do
    for state <- states,
        state["done"] != true,
        not reaches_done?(state["name"], by_name, MapSet.new()),
        do: "#{state["name"]} never reaches done"
  end

  defp reaches_done?(name, by_name, seen) do
    state = by_name[name] || %{}

    cond do
      state["done"] == true ->
        true

      MapSet.member?(seen, name) ->
        false

      true ->
        Enum.any?(List.wrap(state["next"]), &reaches_done?(&1, by_name, MapSet.put(seen, name)))
    end
  end
end
