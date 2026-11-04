defmodule AtlasRuntime.FakeState do
  @moduledoc """
  A stand-in for State on the Bus, for Runtime's tests: answers reads (the description, one
  fact, all of a kind, those linked to a key), stores creates and changes in memory, and
  answers each fact with stored (the Bus hints it to listeners). Its kinds are made up on
  purpose: a clerk owns a box through a card; a run is a turn.
  """
  use GenServer

  alias AtlasBus.Envelope

  def description do
    %{
      "entities" => %{
        "box" => %{"plural" => "boxes"},
        "card" => %{"plural" => "cards"},
        "clerk" => %{"plural" => "clerks"},
        "run" => %{"plural" => "runs"}
      },
      "relations" => %{
        "card" => %{"from" => ["box"], "to" => ["card"], "max_outgoing" => 1},
        "owned_by" => %{"from" => ["card"], "to" => ["clerk"], "max_outgoing" => 1},
        "run_on" => %{"from" => ["run"], "to" => ["card"], "max_outgoing" => 1},
        "run_by" => %{"from" => ["run"], "to" => ["clerk"], "max_outgoing" => 1}
      },
      "flows" => %{
        "pack" => %{
          "kinds" => ["box"],
          "on" => "card",
          "field" => "todo",
          "state_field" => "step",
          "owner_relation" => "owned_by"
        }
      },
      "runtime" => %{
        "turn" => %{
          "kind" => "run",
          "key" => "R-{on}-{n}",
          "on" => "run_on",
          "by" => "run_by",
          "state" => "status",
          "running" => "going",
          "ended" => "over",
          "machine" => "host",
          "lease" => "until",
          "activity" => "last",
          "why" => "reason",
          "ended_at" => "done_at"
        },
        "agent" => %{"cannot_run" => "stuck"}
      }
    }
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Put a fact as State would answer it."
  def put(kind, fact), do: GenServer.call(__MODULE__, {:put, kind, fact})
  def get(kind, key), do: GenServer.call(__MODULE__, {:get, kind, key})
  def all(kind), do: GenServer.call(__MODULE__, {:all, kind})

  @doc "Every fact content sent, oldest first, with its kind."
  def sent, do: GenServer.call(__MODULE__, :sent)

  @impl true
  def init(:ok) do
    :ok = AtlasBus.attach(AtlasBus.store())
    {:ok, %{facts: %{}, sent: [], position: 0}}
  end

  @impl true
  def handle_call({:put, kind, fact}, _from, s) do
    fact = Map.merge(%{"values" => %{}, "links" => %{}}, fact)
    {:reply, :ok, put_in(s.facts[{kind, fact["key"]}], fact)}
  end

  def handle_call({:get, kind, key}, _from, s), do: {:reply, s.facts[{kind, key}], s}

  def handle_call({:all, kind}, _from, s),
    do: {:reply, for({{^kind, _}, fact} <- Enum.sort(s.facts), do: fact), s}

  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
    answer =
      case {e.kind, content} do
        {"_description", _} ->
          %{"description" => description()}

        {kind, %{"key" => key}} ->
          %{"fact" => s.facts[{kind, key}]}

        {kind, %{"linked" => linked}} ->
          facts =
            for {{^kind, _}, fact} <- Enum.sort(s.facts),
                Enum.all?(linked, fn {rel, key} -> key in (fact["links"][rel] || []) end),
                do: fact

          %{"facts" => facts}

        {kind, _} ->
          %{"facts" => for({{^kind, _}, fact} <- Enum.sort(s.facts), do: fact)}
      end

    :ok = AtlasBus.send(Envelope.reply(e, "answer"), answer)
    {:noreply, s}
  end

  def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, %{"key" => key} = c}, s) do
    s = %{s | sent: [{e.kind, c} | s.sent], position: s.position + 1}
    clean = fn values -> Map.reject(values, fn {_, v} -> v in [nil, ""] end) end

    fact =
      case s.facts[{e.kind, key}] do
        nil ->
          %{"key" => key, "values" => clean.(c["values"] || %{}), "links" => c["links"] || %{}}

        fact ->
          %{
            fact
            | "values" => clean.(Map.merge(fact["values"], c["values"] || %{})),
              "links" => Map.merge(fact["links"], c["links"] || %{})
          }
      end

    :ok =
      AtlasBus.send(
        Envelope.reply(e, "stored", position: s.position),
        Map.take(c, ["op", "key", "by"])
      )

    {:noreply, put_in(s.facts[{e.kind, key}], fact)}
  end

  def handle_info(_message, s), do: {:noreply, s}
end
