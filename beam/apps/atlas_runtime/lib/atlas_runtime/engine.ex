defmodule AtlasRuntime.Engine do
  @moduledoc """
  Runtime's engine, on one machine (architecture v4, sections 3, 9 and 13): it runs the
  turns of the agents this machine runs (`AtlasRuntime.Settings`), for the open facts they
  own. Flow decides who owns what; Runtime only runs turns for owners.

  Every round (and at once on a hint about a fact it runs turns on, or a turn) it reads
  State and reconciles, safe to repeat (C2):

  1. A turn State has running on this machine with no process here (Runtime restarted, or
     its process died): ended, with why. It keeps nothing State does not hold (C1).
  2. A turn whose item is no longer its agent's, or no longer open: ended (W1: only the
     owner works on an item).
  3. An open fact owned by one of its agents, without a turn here: a turn is started,
     unless that agent is in a turn already (it then waits behind it, W1).

  What it reads is the description's: the facts a flow writes on (its `on`, or its kinds),
  owned through the flow's `owner_relation`, open while its `state_field` has a value; and
  the turn's kind and fields (`runtime.turn` in `rela/atlas.json`). It names no kind.

  It reaches State only over the Bus, as the endpoint `runtime`.
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope
  alias AtlasRuntime.{Agent, Talk, Turn}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "Reconcile now (for tests)."
  def round(server), do: GenServer.call(server, :round, 30_000)

  @impl true
  def init(opts) do
    :ok = AtlasBus.attach("runtime")
    send(self(), :round)

    {:ok,
     %{
       opts: opts,
       every: Keyword.get(opts, :every, 60_000),
       kinds: MapSet.new(),
       timer: nil,
       soon: false
     }}
  end

  @impl true
  def handle_call(:round, _from, state), do: {:reply, :ok, round_now(state)}

  @impl true
  def handle_info(:round, state), do: {:noreply, round_now(%{state | soon: false})}

  # A hint about a fact it runs turns on, or a turn: look again soon (a burst at once). Its
  # own writes change nothing it reads but the turns it already knows.
  def handle_info({:atlas_bus, %Envelope{class: "stored", kind: kind}, content}, state) do
    cond do
      content["by"] == "runtime" or state.soon or kind not in state.kinds ->
        {:noreply, state}

      true ->
        Process.send_after(self(), :round, 100)
        {:noreply, %{state | soon: true}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp round_now(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    state =
      case Talk.read("_description", %{}) do
        %{"description" => description} -> reconcile(description, state)
        _ -> state
      end

    %{state | timer: Process.send_after(self(), :round, state.every)}
  end

  defp reconcile(description, state) do
    agents = Keyword.get(state.opts, :agents, %{})

    with %{"kind" => _} = names <- get_in(description, ["runtime", "turn"]),
         true <- agents != %{} do
      names = atomize(names)
      kinds = written(description)

      for {kind, _flow} <- kinds, do: AtlasBus.listen(kind)
      AtlasBus.listen(names.kind)

      with {:ok, owned} <- owned(kinds, agents),
           %{"facts" => turns} <- Talk.read(names.kind, %{}) do
        machine = Keyword.fetch!(state.opts, :machine)
        local = local()

        mine =
          for turn <- turns,
              turn["values"][names.state] == names.running,
              turn["values"][names.machine] == machine,
              do: turn

        # 1. Running in State, with no process here.
        for turn <- mine, not Map.has_key?(local, turn["key"]) do
          lost(
            names,
            turn["key"],
            "no process runs it on #{machine} any more (Runtime restarted)"
          )
        end

        # 2. Its item is no longer its agent's, or no longer open.
        for {key, {agent, item}} <- local,
            {agent, item} not in Enum.map(owned, &{&1.agent, &1.item}) do
          [{pid, _}] = Registry.lookup(AtlasRuntime.Turns, key)
          Turn.finish(pid, "#{item} is no longer #{agent}'s to work on")
        end

        # 3. An owned open fact without a turn: one, unless its agent is in one already.
        busy = MapSet.new(for {_key, {agent, _item}} <- local, do: agent)

        owned
        |> Enum.reject(
          &(MapSet.member?(busy, &1.agent) or {&1.agent, &1.item} in Map.values(local))
        )
        |> Enum.uniq_by(& &1.agent)
        |> Enum.each(&start(&1, names, turns, agents, state.opts))

        %{state | kinds: MapSet.new([names.kind | Enum.map(kinds, &elem(&1, 0))])}
      else
        _ -> state
      end
    else
      _ -> state
    end
  end

  # The kinds flows write on, with their definition: `[{kind, flow}]`.
  defp written(description) do
    for {_name, %{"owner_relation" => relation} = flow} <- Enum.sort(description["flows"] || %{}),
        is_binary(relation),
        kind <-
          (case flow["on"] && get_in(description, ["relations", flow["on"], "to"]) do
             [to] -> [to]
             _ -> flow["kinds"] || []
           end),
        uniq: true,
        do: {kind, flow}
  end

  # The open facts each agent owns: `[%{agent, item, kind}]`.
  defp owned(kinds, agents) do
    Enum.reduce_while(kinds, {:ok, []}, fn {kind, flow}, {:ok, acc} ->
      found =
        Enum.reduce_while(Enum.sort(Map.keys(agents)), {:ok, []}, fn agent, {:ok, acc} ->
          case Talk.read(kind, %{"linked" => %{flow["owner_relation"] => agent}, "plain" => true}) do
            %{"facts" => facts} ->
              open =
                for fact <- facts,
                    open?(fact, flow),
                    do: %{agent: agent, item: fact["key"], kind: kind}

              {:cont, {:ok, acc ++ open}}

            _ ->
              {:halt, :unavailable}
          end
        end)

      case found do
        {:ok, more} -> {:cont, {:ok, acc ++ Enum.sort_by(more, & &1.item)}}
        other -> {:halt, other}
      end
    end)
  end

  # Open while Flow has a state for it (its `state_field`); without one, while it is owned.
  defp open?(fact, %{"state_field" => field}) when is_binary(field),
    do: fact["values"][field] not in [nil, ""]

  defp open?(_fact, _flow), do: true

  defp start(owned, names, turns, agents, opts) do
    n = Enum.count(turns, &(owned.item in (get_in(&1, ["links", names.on]) || []))) + 1

    key =
      names.key
      |> String.replace("{on}", owned.item)
      |> String.replace("{n}", Integer.to_string(n))

    case Agent.port(agents[owned.agent]) do
      nil ->
        Logger.warning("runtime: #{owned.agent} has no port this machine knows; no turn")

      port ->
        turn = %{
          key: key,
          item: owned.item,
          agent: owned.agent,
          port: port,
          port_opts: [stub_dir: Keyword.get(opts, :stub_dir)],
          names: names,
          turn_kind: names.kind,
          machine: Keyword.fetch!(opts, :machine),
          silence: Keyword.fetch!(opts, :silence),
          max: Keyword.fetch!(opts, :max),
          lease: Keyword.fetch!(opts, :lease),
          cause: "#{owned.agent} owns #{owned.item}, and no turn of it runs: a turn (#{n})"
        }

        DynamicSupervisor.start_child(AtlasRuntime.Supervisor, {Turn, turn})
    end
  end

  # A turn without its process: ended in State, with why.
  defp lost(names, key, why) do
    content = %{
      "op" => "change",
      "key" => key,
      "values" => %{names.state => names.ended, names.why => why, names.lease => ""},
      "version" => nil,
      "by" => "runtime",
      "cause" => why
    }

    case Talk.put(names.kind, content) do
      {:stored, _} -> Logger.info("runtime: #{key} ended: #{why}")
      other -> Logger.warning("runtime: #{key} not ended: #{inspect(other)}; tried again")
    end
  end

  # The turns running here: `%{key => {agent, item}}`.
  defp local do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasRuntime.Supervisor),
        is_pid(pid),
        [{key, value}] <- [Registry.keys(AtlasRuntime.Turns, pid) |> Enum.map(&{&1, value(&1)})],
        value != nil,
        into: %{},
        do: {key, value}
  end

  defp value(key) do
    case Registry.lookup(AtlasRuntime.Turns, key) do
      [{_pid, value}] -> value
      _ -> nil
    end
  end

  @names ~w(kind key on by state running ended machine lease activity why)

  defp atomize(names), do: Map.new(@names, &{String.to_atom(&1), names[&1]})
end
