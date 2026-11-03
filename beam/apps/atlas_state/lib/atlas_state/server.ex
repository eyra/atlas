defmodule AtlasState.Server do
  @moduledoc """
  State on the Bus: the store endpoint. Generic: what a kind is, it reads from rela.

  - A `fact` is stored in rela and answered with one `stored` (acknowledgement and hint,
    with the fact's position) or one `refused` (final, with reasons). Never silence.
    A resent id gets its first answer again and is not stored twice.
  - A `read` is answered with the facts of a kind (all, or `"linked" => %{relation => key}`
    for those that point at `key`), one fact (`"key" => key`) with the keys of the facts
    that point at it, or (kind `_description`) rela's description. Facts carry their
    outgoing `links`.

  Fact content: `%{"op" => "create" | "change" | "delete", "key" => id,
  "values" => %{property => value}, "version" => version read before, or nil,
  "links" => %{relation => [keys]} on a create}`.
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope
  alias AtlasState.{Description, Ledger, Rela}

  @description "_description"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @impl true
  def init(opts) do
    :ok = AtlasBus.attach(AtlasBus.store())
    ledger = Ledger.open(Keyword.fetch!(opts, :data_dir))

    {:ok,
     %{
       rela: Keyword.fetch!(opts, :rela),
       ledger: ledger,
       description: nil,
       extra: Keyword.get(opts, :description_extra)
     }}
  end

  @impl true
  def terminate(_reason, state), do: Ledger.close(state.ledger)

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "fact"} = envelope, content}, state) do
    case Ledger.answer(state.ledger, envelope.id) do
      {class, answer, position} ->
        reply(envelope, class, answer, position)
        {:noreply, state}

      nil ->
        {result, state} = store(state, envelope.kind, content)
        answer(state, envelope, content, result)
        {:noreply, state}
    end
  end

  def handle_info({:atlas_bus, %Envelope{class: "read"} = envelope, content}, state) do
    {answer, state} = read(state, envelope.kind, content || %{})
    reply(envelope, "answer", Map.put(answer, "position", Ledger.position(state.ledger)), nil)
    {:noreply, state}
  end

  def handle_info({:atlas_bus, _envelope, _content}, state), do: {:noreply, state}

  defp answer(state, envelope, content, result) do
    about = %{"op" => content_op(content), "key" => content_key(content)}

    case result do
      :stored ->
        position = Ledger.stored(state.ledger, envelope.id, about)
        reply(envelope, "stored", about, position)

      {:refused, reasons} ->
        answer(state, envelope, content, {:refused, reasons, nil})

      # A code says why in a way a sender can act on: "exists" or "reserved" (the id is
      # taken), so a sender that made the id up can try the next one.
      {:refused, reasons, code} ->
        refusal = Map.put(about, "reasons", reasons)
        refusal = if code, do: Map.put(refusal, "code", code), else: refusal
        Ledger.refused(state.ledger, envelope.id, refusal)
        reply(envelope, "refused", refusal, nil)

      # Not recorded: the same id may be stored once rela is back.
      :unavailable ->
        reply(envelope, "refused", Map.put(about, "reasons", ["rela is not reachable"]), nil)
    end
  end

  defp reply(envelope, class, content, position) do
    case AtlasBus.send(Envelope.reply(envelope, class, position: position), content) do
      :ok -> :ok
      error -> Logger.warning("State could not answer #{envelope.id}: #{inspect(error)}")
    end
  end

  # rela's description, with Atlas's additions (`rela/atlas.json`) merged in, key by key.
  # The file is read every time, so a change to it needs no restart.
  defp describe(state) do
    with {:ok, description} <- Rela.description(state.rela) do
      {:ok, Description.merge(description, extra(state.extra))}
    end
  end

  defp extra(nil), do: %{}

  defp extra(path) do
    with {:ok, json} <- File.read(path),
         {:ok, extra} <- JSON.decode(json) do
      Map.drop(extra, ["_about"])
    else
      error ->
        Logger.warning(
          "State could not read #{path}: #{inspect(error)}; using rela's description alone"
        )

        %{}
    end
  end

  # Reads

  defp read(state, @description, _content) do
    case describe(state) do
      {:ok, description} -> {%{"description" => description}, %{state | description: description}}
      {:error, _} -> {%{"error" => "rela is not reachable"}, state}
    end
  end

  defp read(state, kind, content) do
    with {:ok, spec, state} <- kind_spec(state, kind) do
      case content do
        %{"key" => key} -> {read_one(state, kind, spec, key), state}
        %{"linked" => linked} when is_map(linked) -> {read_all(state, spec, linked), state}
        _ -> {read_all(state, spec, %{}), state}
      end
    else
      {:error, reason, state} -> {%{"error" => reason}, state}
    end
  end

  defp read_all(state, spec, linked) do
    case Rela.list(state.rela, spec["plural"]) do
      {:ok, facts} ->
        facts =
          Enum.filter(facts, fn fact ->
            Enum.all?(linked, fn {rel, key} -> key in (fact.links[rel] || []) end)
          end)

        %{"facts" => Enum.map(facts, &wire/1)}

      {:error, _} ->
        %{"error" => "rela is not reachable"}
    end
  end

  defp read_one(state, kind, spec, key) do
    with {:ok, fact} <- Rela.get(state.rela, spec["plural"], key),
         {:ok, incoming} <- incoming(state, kind, spec, key) do
      %{"fact" => wire(fact), "incoming" => incoming}
    else
      {:error, :not_found} -> %{"fact" => nil}
      {:error, _} -> %{"error" => "rela is not reachable"}
    end
  end

  defp incoming(state, kind, spec, key) do
    Description.incoming(state.description, kind)
    |> Enum.reduce_while({:ok, %{}}, fn {relation, _from}, {:ok, acc} ->
      case Rela.incoming(state.rela, spec["plural"], key, relation) do
        {:ok, keys} -> {:cont, {:ok, Map.put(acc, relation, keys)}}
        error -> {:halt, error}
      end
    end)
  end

  defp wire(fact),
    do: %{
      "key" => fact.key,
      "values" => fact.properties,
      "links" => fact[:links] || %{},
      "version" => fact.version
    }

  # Facts

  defp store(state, kind, %{"op" => op, "key" => key} = content) when is_binary(key) do
    case kind_spec(state, kind) do
      {:ok, spec, state} ->
        values = content["values"] || %{}

        result =
          case Description.targets(state.description, kind, content["links"] || %{}) do
            {:ok, targets} ->
              with :ok <- targets_exist(state, op, targets) do
                store(state.rela, spec, op, key, values, content["version"], targets)
              end

            {:error, problems} ->
              {:refused, problems}
          end

        {result, state}

      {:error, :unavailable, state} ->
        {:unavailable, state}

      {:error, reason, state} ->
        {{:refused, [reason]}, state}
    end
  end

  defp store(state, _kind, _content), do: {{:refused, ["a fact needs an op and a key"]}, state}

  defp store(rela, spec, "create", key, values, _version, targets) do
    values = Map.reject(values, fn {_, v} -> v in [nil, ""] end)
    plural = spec["plural"]

    with :ok <- both(Description.check_key(spec, key), Description.check(spec, values, :create)),
         {:ok, []} <- Rela.check_create(rela, plural, key, values, targets),
         {:ok, _warnings} <- Rela.create(rela, plural, key, values, targets) do
      :stored
    else
      {:ok, warnings} -> {:refused, warnings}
      {:error, :exists} -> resent_create(rela, plural, key, values, targets)
      error -> failure(error)
    end
  end

  # Links are set on create only; moving a fact to another parent comes later.
  defp store(rela, spec, "change", key, values, version, _targets) do
    values = Map.new(values, fn {k, v} -> {k, if(v == "", do: nil, else: v)} end)
    plural = spec["plural"]

    with :ok <- Description.check(spec, values, :change),
         {:ok, []} <- Rela.change(rela, plural, key, values, version) do
      :stored
    else
      # The current rela has already stored the change; say so instead of hiding it.
      {:ok, warnings} -> {:refused, ["rela stored it with warnings: " | warnings]}
      {:error, :version_mismatch} -> changed_meanwhile(rela, plural, key, values)
      {:error, :not_found} -> {:refused, ["#{key} does not exist (any more)"]}
      error -> failure(error)
    end
  end

  defp store(rela, spec, "delete", key, _values, version, _targets) do
    # The current rela ignores If-Match on delete, so State compares the version itself.
    current =
      case Rela.get(rela, spec["plural"], key) do
        {:ok, %{version: current}} when version != nil and current != version -> :changed
        _ -> :same
      end

    result =
      if current == :changed,
        do: {:error, :version_mismatch},
        else: Rela.delete(rela, spec["plural"], key, version)

    case result do
      :ok -> :stored
      # Gone is what was asked for: a resent delete after a lost answer.
      {:error, :not_found} -> :stored
      {:error, :version_mismatch} -> {:refused, ["#{key} changed meanwhile; open it again"]}
      error -> failure(error)
    end
  end

  defp store(_rela, _spec, op, _key, _values, _version, _targets),
    do: {:refused, ["unknown op #{inspect(op)}"]}

  defp both(:ok, :ok), do: :ok
  defp both(first, second), do: {:error, problems(first) ++ problems(second)}

  defp problems(:ok), do: []
  defp problems({:error, problems}), do: problems

  # A create of an existing id: the same fact sent again (stored), or a clash (refused).
  defp resent_create(rela, plural, key, values, targets) do
    case Rela.get(rela, plural, key) do
      {:ok, fact} ->
        if same?(fact, values) and same_links?(fact, targets),
          do: :stored,
          else: {:refused, ["#{key} already exists"], "exists"}

      {:error, :not_found} ->
        {:refused,
         [
           "#{key} was deleted a moment ago; rela keeps a deleted id reserved for a few " <>
             "minutes. Try again later, or use another id."
         ], "reserved"}

      error ->
        failure(error)
    end
  end

  # A change on an old version: already applied (a resend) or a real conflict.
  defp changed_meanwhile(rela, plural, key, values) do
    case Rela.get(rela, plural, key) do
      {:ok, fact} ->
        if same?(fact, values),
          do: :stored,
          else: {:refused, ["#{key} changed meanwhile; open it again"]}

      error ->
        failure(error)
    end
  end

  defp same_links?(fact, targets) do
    Enum.all?(targets, fn {relation, {_kind, keys}} ->
      Enum.sort(fact.links[relation] || []) == Enum.sort(keys)
    end)
  end

  # The current rela answers 422 to a create that links to a missing fact, but stores the
  # fact anyway, without the link. So State checks the targets exist before it creates.
  defp targets_exist(state, "create", targets) do
    missing =
      for {_relation, {kind, keys}} <- targets,
          key <- keys,
          Rela.get(state.rela, get_in(state.description, ["entities", kind, "plural"]), key) ==
            {:error, :not_found},
          do: "#{key} does not exist"

    if missing == [], do: :ok, else: {:refused, missing}
  end

  defp targets_exist(_state, _op, _targets), do: :ok

  defp same?(fact, values) do
    Enum.all?(values, fn {name, value} -> loose(fact.properties[name]) == loose(value) end)
  end

  defp loose(value) when value in [nil, ""], do: nil
  defp loose(value), do: to_string(value)

  defp failure({:error, :unavailable}), do: :unavailable
  defp failure({:error, {:invalid, problems}}), do: {:refused, problems}
  defp failure({:error, problems}) when is_list(problems), do: {:refused, problems}
  defp failure({:error, other}), do: {:refused, [inspect(other)]}

  defp kind_spec(state, kind) do
    case state.description && Description.kind(state.description, kind) do
      nil ->
        case describe(state) do
          {:ok, description} ->
            state = %{state | description: description}

            case Description.kind(description, kind) do
              nil -> {:error, "rela does not describe #{inspect(kind)}", state}
              spec -> {:ok, spec, state}
            end

          {:error, _} ->
            {:error, :unavailable, state}
        end

      spec ->
        {:ok, spec, state}
    end
  end

  defp content_op(%{"op" => op}) when is_binary(op), do: op
  defp content_op(_), do: nil
  defp content_key(%{"key" => key}) when is_binary(key), do: key
  defp content_key(_), do: nil
end
