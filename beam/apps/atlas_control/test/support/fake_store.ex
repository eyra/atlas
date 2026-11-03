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
          "id_prefixes" => ["P-"],
          "primary" => "title",
          "properties" => %{"title" => %{"type" => "string", "required" => true}}
        }
      },
      "relations" => %{
        "of_widget" => %{
          "label" => "of widget",
          "from" => ["part"],
          "to" => ["widget"],
          "max_outgoing" => 1,
          "inverse" => %{"id" => "parts", "label" => "parts"}
        }
      }
    }
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def put(key, values, kind \\ "widget", links \\ %{}),
    do: GenServer.call(__MODULE__, {:put, kind, key, values, links})

  def link(part, widget), do: put(part, %{"title" => part}, "part", %{"of_widget" => [widget]})
  def silent(on?), do: GenServer.call(__MODULE__, {:silent, on?})

  @doc "Make a key taken without listing it, as rela does for a key deleted a moment ago."
  def reserve(key), do: GenServer.call(__MODULE__, {:reserve, key})

  @impl true
  def init(:ok) do
    :ok = AtlasBus.attach(AtlasBus.store())
    {:ok, %{facts: %{}, position: 0, silent: false, reserved: MapSet.new()}}
  end

  @impl true
  def handle_call({:put, kind, key, values, links}, _from, s),
    do: {:reply, :ok, put_in(s.facts[{kind, key}], {values, 0, links})}

  def handle_call({:silent, on?}, _from, s), do: {:reply, :ok, %{s | silent: on?}}

  def handle_call({:reserve, key}, _from, s),
    do: {:reply, :ok, %{s | reserved: MapSet.put(s.reserved, key)}}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
    answer =
      case {e.kind, content} do
        {"_description", _} ->
          %{"description" => description()}

        {kind, %{"key" => key}} ->
          case s.facts[{kind, key}] do
            nil ->
              %{"fact" => nil}

            {values, n, links} ->
              incoming =
                for {relation, %{"to" => to}} <- description()["relations"],
                    kind in to,
                    into: %{} do
                  {relation,
                   for({{_, k}, {_, _, l}} <- s.facts, key in (l[relation] || []), do: k)}
                end

              %{
                "fact" => %{
                  "key" => key,
                  "values" => values,
                  "links" => links,
                  "version" => "v#{n}"
                },
                "incoming" => incoming
              }
          end

        {kind, content} ->
          linked = content["linked"] || %{}

          facts =
            for {{^kind, k}, {v, _, l}} <- Enum.sort(s.facts),
                Enum.all?(linked, fn {rel, parent} -> parent in (l[rel] || []) end),
                do: %{"key" => k, "values" => v, "links" => l, "version" => nil}

          %{"facts" => facts}
      end

    :ok = AtlasBus.send(Envelope.reply(e, "answer"), Map.put(answer, "position", s.position))
    {:noreply, s}
  end

  def handle_info({:atlas_bus, %Envelope{class: "fact"}, _content}, %{silent: true} = s),
    do: {:noreply, s}

  def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, %{"op" => op, "key" => key} = c}, s) do
    about = %{"op" => op, "key" => key}
    id = {e.kind, key}

    cond do
      op == "create" and c["values"]["title"] in [nil, ""] ->
        :ok =
          AtlasBus.send(
            Envelope.reply(e, "refused"),
            Map.put(about, "reasons", ["title is required"])
          )

        {:noreply, s}

      op == "create" and (Map.has_key?(s.facts, id) or key in s.reserved) ->
        code = if key in s.reserved, do: "reserved", else: "exists"
        refusal = Map.merge(about, %{"reasons" => ["#{key} is taken"], "code" => code})
        :ok = AtlasBus.send(Envelope.reply(e, "refused"), refusal)
        {:noreply, s}

      true ->
        facts =
          case op do
            "delete" ->
              Map.delete(s.facts, id)

            "create" ->
              Map.put(s.facts, id, {c["values"], 0, c["links"] || %{}})

            "change" ->
              Map.update!(s.facts, id, fn {old, n, l} ->
                {Map.merge(old, c["values"]), n + 1, l}
              end)
          end

        s = %{s | facts: facts, position: s.position + 1}
        :ok = AtlasBus.send(Envelope.reply(e, "stored", position: s.position), about)
        {:noreply, s}
    end
  end
end
