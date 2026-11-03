defmodule AtlasFlow.Item do
  @moduledoc """
  One open fact's process (architecture, rule 2): alive while the fact is open, with a
  timer in every state. On its timer, and at once when poked (a hint), it reads its fact
  and what hangs under it from State, works out its state from the flow definition, and
  when the owner or what is expected differs from what is stored, stores the change, with
  its cause. It keeps nothing State does not hold: restarted at any moment, it goes on
  from State. When its fact is done (or gone) it stops.

  Registered as `{kind, key}` in `AtlasFlow.Items`, so there is one per fact; starting a
  second one fails.
  """
  use GenServer, restart: :transient

  require Logger

  alias AtlasFlow.{Definition, Talk}

  # A burst of hints is looked at once.
  @settle 50

  def start_link({kind, key, opts}),
    do: GenServer.start_link(__MODULE__, {kind, key, opts}, name: via(kind, key))

  def via(kind, key), do: {:via, Registry, {AtlasFlow.Items, {kind, key}}}

  @doc """
  Look again soon: something it depends on may have changed. `description` is the
  engine's copy (read every round), so a poke costs no read of it; the timer reads it.
  """
  def poke(pid, description \\ nil), do: send(pid, {:poke, description})

  @impl true
  def init({kind, key, opts}) do
    :ok = AtlasBus.attach("flow/#{kind}/#{key}")
    send(self(), :look)

    {:ok,
     %{
       kind: kind,
       key: key,
       every: Keyword.fetch!(opts, :every),
       timer: nil,
       soon: false,
       description: nil
     }}
  end

  @impl true
  def handle_info({:poke, description}, %{soon: true} = state),
    do: {:noreply, %{state | description: description || state.description}}

  def handle_info({:poke, description}, state) do
    Process.send_after(self(), {:look, :poked}, @settle)
    {:noreply, %{state | soon: true, description: description}}
  end

  # On its timer it reads everything, the description too.
  def handle_info(:look, state), do: handle_info({:look, :timer}, %{state | description: nil})

  def handle_info({:look, _why}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    state = %{state | soon: false, timer: nil}

    case look(state) do
      {:wait, every} -> {:noreply, %{state | timer: Process.send_after(self(), :look, every)}}
      :stop -> {:stop, :normal, state}
    end
  end

  # Answers that came after their wait, and anything else.
  def handle_info(_message, state), do: {:noreply, state}

  defp look(state) do
    with %{"description" => description} <- description(state),
         {name, flow} <- Definition.for_kind(description, state.kind),
         %{"fact" => fact} when is_map(fact) <-
           Talk.read(state.kind, %{"key" => state.key, "incoming" => false}) do
      parents = parent_relations(description, state.kind)
      children = children(parents, description, state.key)
      {current, vars} = Definition.state_of(flow, fact, children, parents)
      move(state, description, {name, flow}, fact, current, vars)

      if current["done"],
        do: :stop,
        else: {:wait, Definition.every(current || %{}, state.every)}
    else
      # Gone, or no flow runs on it any more: nothing to keep alive.
      %{"fact" => nil} -> :stop
      nil -> :stop
      # State did not answer: try again on the timer.
      _ -> {:wait, state.every}
    end
  end

  defp description(%{description: nil}), do: Talk.read("_description", %{})
  defp description(%{description: description}), do: %{"description" => description}

  # Store what differs: what is expected, and the owner, in one change with its cause, on
  # the fact the definition writes on: its own, or the one its `on` relation points at.
  defp move(state, description, {name, flow}, fact, current, vars) do
    case written(description, flow, state.kind, fact) do
      {:ok, kind, target} ->
        write(state, name, flow, kind, target, current, vars)

      {:missing, relation} ->
        Logger.warning("flow #{name}: #{state.key} has no #{relation} to write on; tried again")

      :unavailable ->
        :ok
    end
  end

  defp written(description, %{"on" => relation}, _kind, fact) when is_binary(relation) do
    with [to] <- get_in(description, ["relations", relation, "to"]),
         [key] <- get_in(fact, ["links", relation]) || [],
         %{"fact" => target} when is_map(target) <-
           Talk.read(to, %{"key" => key, "plain" => true}) do
      {:ok, to, target}
    else
      %{"fact" => nil} -> {:missing, relation}
      %{"error" => _} -> :unavailable
      _ -> {:missing, relation}
    end
  end

  defp written(_description, _flow, kind, fact), do: {:ok, kind, fact}

  defp write(state, name, flow, kind, fact, current, vars) do
    expected = Definition.expected(current, vars)
    field = flow["field"]

    values =
      if field && blank(fact["values"][field]) != blank(expected),
        do: %{field => expected || ""},
        else: %{}

    owner = Definition.owner(current)
    relation = flow["owner_relation"]
    moved? = values != %{}

    owner? =
      if (relation && (get_in(fact, ["links", relation]) || []) != List.wrap(owner)) and
           (moved? or not by_hand?(fact, relation)),
         do: owner_exists(current),
         else: :no

    links = if owner? == :yes, do: %{relation => List.wrap(owner)}, else: %{}

    # The state's name, so a page can show its owner what to do (`state_field`). Written
    # with the rest, and alone when only it differs; it never counts as a move by itself.
    values = Map.merge(values, state_value(flow["state_field"], fact, current))

    cond do
      # State did not say whether the owner exists: write nothing now, rather than what
      # is expected without its owner; the timer tries again.
      owner? == :unknown ->
        Logger.warning("flow #{name}: #{state.key} not moved: State did not answer; tried again")

      values != %{} or links != %{} ->
        # By flow: Flow passes over the hints of its own writes, on whichever fact.
        content = %{
          "op" => "change",
          "key" => fact["key"],
          "values" => values,
          "version" => nil,
          "by" => "flow",
          "cause" => cause(name, current, owner)
        }

        content = if links == %{}, do: content, else: Map.put(content, "links", links)

        case Talk.put(kind, content) do
          {:stored, _} ->
            Logger.info("flow #{name}: #{state.key} #{current["name"]} (#{inspect(values)})")

          other ->
            Logger.warning("flow #{name}: #{state.key} not moved: #{inspect(other)}; tried again")
        end

      true ->
        :ok
    end
  end

  # An owner a user or an agent set stays while the state does not change: Flow moves it
  # only when the state changes (what is expected changes), or when Flow, a migration or
  # nobody set it.
  defp by_hand?(fact, relation) do
    case get_in(fact, ["origins", relation]) do
      %{"by" => by} when by not in [nil, "flow", "migration"] -> true
      _ -> false
    end
  end

  # The owner a state names must exist; until it does, only what is expected is written.
  # :yes, :no (State says there is no such fact), or :unknown (State did not answer).
  defp owner_exists(current) do
    case {Definition.owner(current), Definition.owner_kind(current)} do
      {key, kind} when is_binary(key) and is_binary(kind) ->
        case Talk.read(kind, %{"key" => key, "plain" => true}) do
          %{"fact" => %{}} ->
            :yes

          %{"fact" => nil} ->
            Logger.warning("flow: #{kind} #{key} does not exist; the owner waits for it")
            :no

          _ ->
            :unknown
        end

      _ ->
        :yes
    end
  end

  defp cause(name, current, owner) do
    why = current["why"] || current["name"]
    to = if owner, do: " → #{owner}", else: ""
    "Flow #{name}: #{why}#{to}"
  end

  defp state_value(nil, _fact, _current), do: %{}

  defp state_value(field, fact, current) do
    name = if current && !current["done"], do: current["name"], else: nil
    if blank(fact["values"][field]) == blank(name), do: %{}, else: %{field => name || ""}
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  # The relations by which facts belong under one of `kind`, as the description marks them.
  defp parent_relations(description, kind) do
    for {relation, %{"parent" => true, "to" => to}} <- description["relations"] || %{},
        kind in to,
        do: relation
  end

  defp children(parents, description, key) do
    Enum.flat_map(parents, fn relation ->
      [from | _] = get_in(description, ["relations", relation, "from"]) || [nil]

      case from && Talk.read(from, %{"linked" => %{relation => key}, "plain" => true}) do
        %{"facts" => facts} -> facts
        _ -> []
      end
    end)
  end
end
