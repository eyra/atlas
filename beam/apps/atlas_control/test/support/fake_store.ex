defmodule AtlasControl.FakeStore do
  @moduledoc """
  A stand-in for State on the Bus, for Control's tests: answers reads, stores facts in
  memory, answers every fact with stored or refused. Its kinds are made up on purpose.
  """
  use GenServer

  alias AtlasBus.Envelope

  def description do
    %{
      "entities" => %{
        "widget" => %{
          "label" => "Widget",
          "plural" => "widgets",
          "primary" => "title",
          "id_type" => "manual",
          "id_prefixes" => ["W-"],
          "properties" => %{
            "title" => %{"type" => "string", "required" => true},
            "shade" => %{
              "type" => "shade",
              "values" => ["light", "dark"],
              "labels" => %{"light" => "Light", "dark" => "Dark"}
            },
            "done" => %{"type" => "boolean", "default" => "false"},
            "notes" => %{"type" => "string", "description" => "Free text"},
            # Only a connector fills it, as `rela/atlas.json` marks it.
            "ext_ref" => %{"type" => "string", "set_by" => "connector"}
          },
          # As `rela/atlas.json` adds it.
          "create" => %{
            "ask" => ["title", "notes"],
            "id" => %{"prefix" => "W-", "digits" => 2},
            "defaults" => %{"shade" => "light", "done" => false}
          }
        },
        "part" => %{
          "label" => "Part",
          "plural" => "parts",
          "primary" => "title",
          "properties" => %{"title" => %{"type" => "string", "required" => true}}
        }
      },
      "relations" => %{
        "of_widget" => %{
          "from" => ["part"],
          "to" => ["widget"],
          "max_outgoing" => 1,
          "inverse" => %{"id" => "parts", "label" => "parts"}
        }
      }
    }
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def put(key, values), do: GenServer.call(__MODULE__, {:put, key, values})
  def link(part, widget), do: GenServer.call(__MODULE__, {:link, part, widget})
  def silent(on?), do: GenServer.call(__MODULE__, {:silent, on?})

  @doc "Make a key taken without listing it, as rela does for a key deleted a moment ago."
  def reserve(key), do: GenServer.call(__MODULE__, {:reserve, key})

  @impl true
  def init(:ok) do
    :ok = AtlasBus.attach(AtlasBus.store())
    {:ok, %{facts: %{}, links: %{}, position: 0, silent: false, reserved: MapSet.new()}}
  end

  @impl true
  def handle_call({:put, key, values}, _from, s),
    do: {:reply, :ok, put_in(s.facts[key], {values, 0})}

  def handle_call({:link, part, widget}, _from, s),
    do: {:reply, :ok, put_in(s.links[part], widget)}

  def handle_call({:silent, on?}, _from, s), do: {:reply, :ok, %{s | silent: on?}}

  def handle_call({:reserve, key}, _from, s),
    do: {:reply, :ok, %{s | reserved: MapSet.put(s.reserved, key)}}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
    answer =
      case {e.kind, content} do
        {"_description", _} ->
          %{"description" => description()}

        {"widget", %{"key" => key}} ->
          case s.facts[key] do
            nil ->
              %{"fact" => nil}

            {values, n} ->
              parts = for {part, ^key} <- s.links, do: part

              %{
                "fact" => %{"key" => key, "values" => values, "version" => "v#{n}"},
                "incoming" => %{"of_widget" => parts}
              }
          end

        {"widget", _} ->
          %{
            "facts" =>
              for({k, {v, _}} <- s.facts, do: %{"key" => k, "values" => v, "version" => nil})
          }
      end

    :ok = AtlasBus.send(Envelope.reply(e, "answer"), Map.put(answer, "position", s.position))
    {:noreply, s}
  end

  def handle_info({:atlas_bus, %Envelope{class: "fact"}, _content}, %{silent: true} = s),
    do: {:noreply, s}

  def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, %{"op" => op, "key" => key} = c}, s) do
    about = %{"op" => op, "key" => key}

    cond do
      op == "create" and c["values"]["title"] in [nil, ""] ->
        :ok =
          AtlasBus.send(
            Envelope.reply(e, "refused"),
            Map.put(about, "reasons", ["title is required"])
          )

        {:noreply, s}

      op == "create" and (Map.has_key?(s.facts, key) or key in s.reserved) ->
        code = if key in s.reserved, do: "reserved", else: "exists"
        refusal = Map.merge(about, %{"reasons" => ["#{key} is taken"], "code" => code})
        :ok = AtlasBus.send(Envelope.reply(e, "refused"), refusal)
        {:noreply, s}

      true ->
        facts =
          case op do
            "delete" ->
              Map.delete(s.facts, key)

            _ ->
              Map.update(s.facts, key, {c["values"], 0}, fn {old, n} ->
                {Map.merge(old, c["values"]), n + 1}
              end)
          end

        s = %{s | facts: facts, position: s.position + 1}
        :ok = AtlasBus.send(Envelope.reply(e, "stored", position: s.position), about)
        {:noreply, s}
    end
  end
end
