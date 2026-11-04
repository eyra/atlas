defmodule AtlasState.Guidance do
  @moduledoc """
  Immutable execution, interaction and receipt operations, selected by description.

  State is the sole write authority. A deterministic identity is claimed with the
  backend's create-if-absent, never a client-side lookup/registry. On an existing
  identity the complete immutable payload is compared, not just its digest.
  Recovered creates retain the original server timestamp. Receipts are append-only;
  projections are rebuilt from evidence and never persisted as mutable status.

  Control is an admitted identity boundary (as for existing Control clients): only
  a Control session may assert `by`. Runtime endpoints are bound to machines by the
  Bus link. Receipt fields cannot substitute for that authenticated envelope sender.
  """
  alias AtlasState.{Description, Rela}

  @roles ~w(execution interaction receipt)
  @execution ~w(worker turn attempt machine harness harness_version configured_model capability_version queued_input durable_accept_query consumption_evidence)
  @interaction ~w(client_key body worker turn attempt mode execution cause)
  @receipt ~w(interaction worker turn attempt execution stage evidence_id cause)
  @stages ~w(delivered acknowledged uncertain stale unsupported rejected)

  def role(description, kind) do
    Enum.find(@roles, &(get_in(description, ["guidance", &1, "kind"]) == kind))
  end

  def write(rela, description, role, envelope, content, next_position) when is_map(content) do
    with true <- envelope.environment == AtlasBus.environment(),
         {:ok, values} <- operation(rela, description, role, envelope, content),
         {:ok, fact} <- immutable(rela, description, role, values, next_position),
         {:ok, view} <- view(rela, description, role, fact) do
      {:ok, view}
    else
      false -> {:error, :wrong_environment}
      error -> error
    end
  end

  def write(_rela, _description, _role, _envelope, _content, _next_position),
    do: {:error, :invalid_operation}

  def read(rela, description, role, content) when is_map(content) do
    collection = plural(description, role)

    case content do
      %{"key" => key} when is_binary(key) ->
        with {:ok, fact} <- Rela.get(rela, collection, key),
             {:ok, view} <- view(rela, description, role, fact) do
          {:ok, %{"fact" => view}}
        end

      %{"actor" => actor, "client_key" => client_key} when role == "interaction" ->
        read(rela, description, role, %{
          "key" => identity(["interaction", AtlasBus.environment(), actor, client_key])
        })

      %{"execution" => execution} when role == "interaction" and is_binary(execution) ->
        after_position = content["after_position"] || 0
        limit = content["limit"] || 100

        if is_integer(after_position) and after_position >= 0 and is_integer(limit) and
             limit in 1..100 do
          with {:ok, facts} <- Rela.list(rela, collection) do
            selected =
              facts
              |> Enum.filter(fn fact ->
                v = decode(description, role, fact)

                v["environment"] == AtlasBus.environment() and v["execution"] == execution and
                  v["recorded_position"] > after_position
              end)
              |> Enum.sort_by(&decode(description, role, &1)["recorded_position"])

            page = Enum.take(selected, limit)

            Enum.reduce_while(page, {:ok, []}, fn fact, {:ok, acc} ->
              case view(rela, description, role, fact) do
                {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
                error -> {:halt, error}
              end
            end)
            |> case do
              {:ok, values} ->
                {:ok,
                 %{
                   "facts" => values,
                   "more" => length(selected) > limit,
                   "after_position" =>
                     if(values == [],
                       do: after_position,
                       else: List.last(values)["recorded_position"]
                     )
                 }}

              error ->
                error
            end
          end
        else
          {:error, :invalid_page}
        end

      _ ->
        {:error, :exact_identity_required}
    end
  end

  def read(_, _, _, _), do: {:error, :invalid_operation}

  @doc "Protect the authority of fenced turns, including attempts introduced by this protocol."
  def authorize_turn(rela, d, e, content) do
    turn = get_in(d, ["runtime", "turn"])

    if is_map(turn) and is_binary(turn["attempt"]) and e.kind == turn["kind"] and is_map(content) do
      authorize_fenced_turn(rela, d, e, content, turn)
    else
      :ok
    end
  end

  defp authorize_fenced_turn(rela, d, e, content, turn) do
    with key when is_binary(key) <- content["key"],
         values when is_map(values) <- content["values"] || %{} do
      existing =
        case Rela.get(rela, kind_plural(d, turn["kind"]), content["key"]) do
          {:ok, fact} -> fact.properties
          _ -> %{}
        end

      fenced = Map.has_key?(values, turn["attempt"]) or Map.has_key?(existing, turn["attempt"])
      machine = existing[turn["machine"]] || values[turn["machine"]]

      unchanged_fence =
        not Map.has_key?(existing, turn["attempt"]) or
          Enum.all?([turn["attempt"], turn["machine"]], fn field ->
            not Map.has_key?(values, field) or values[field] == existing[field]
          end)

      outcome_only =
        content["op"] == "change" and Map.keys(values) == [turn["outcome"]] and
          (content["links"] || %{}) == %{} and is_binary(e.sender) and
          String.starts_with?(e.sender, "control/session-")

      if not fenced or
           (unchanged_fence and (runtime?(e.sender, machine, content["key"]) or outcome_only)),
         do: :ok,
         else: {:error, :turn_authority}
    else
      _ -> {:error, :invalid_operation}
    end
  end

  defp operation(rela, d, "execution", e, %{"op" => "register_execution", "values" => v})
       when is_map(v) do
    turn = d["runtime"]["turn"]

    with :ok <- shape(v, @execution, ~w(reported_model)),
         true <- runtime?(e.sender, v["machine"], v["turn"]),
         true <-
           Enum.all?(
             ~w(queued_input durable_accept_query consumption_evidence),
             &is_boolean(v[&1])
           ),
         {:ok, fact} <- Rela.get(rela, kind_plural(d, turn["kind"]), v["turn"]),
         true <- fact.properties[turn["machine"]] == v["machine"],
         true <- fact.properties[turn["attempt"]] == v["attempt"],
         true <- v["worker"] in Map.get(fact.links, turn["by"], []),
         true <- fact.properties[turn["state"]] == turn["running"] do
      {:ok, Map.put(v, "environment", e.environment)}
    else
      false -> {:error, :execution_authority}
      error -> error
    end
  end

  defp operation(rela, d, "interaction", e, %{
         "op" => "submit_interaction",
         "by" => actor,
         "values" => v
       })
       when is_map(v) and is_binary(actor) and actor != "" do
    with :ok <- shape(v, @interaction, []),
         true <- is_binary(e.sender) and String.starts_with?(e.sender, "control/session-"),
         values =
           v
           |> Map.put("actor", actor)
           |> Map.put("environment", e.environment)
           |> Map.put("body_digest", digest(v["body"])),
         :ok <- replay_payload(rela, d, "interaction", values),
         true <- v["mode"] == "queued_guidance",
         {:ok, execution} <- fetch(rela, d, "execution", v["execution"]),
         true <- target?(v, execution),
         true <- execution["environment"] == e.environment,
         :ok <- capable(execution) do
      # Persistence reserves no turn; admission eligibility is Runtime's responsibility.
      {:ok, values}
    else
      false -> {:error, :interaction_authority}
      error -> error
    end
  end

  defp operation(rela, d, "receipt", e, %{"op" => "record_receipt", "values" => v})
       when is_map(v) do
    with :ok <- shape(v, @receipt, ~w(admission_id consumption_id reason)),
         true <- v["stage"] in @stages,
         {:ok, interaction} <- fetch(rela, d, "interaction", v["interaction"]),
         {:ok, execution} <- fetch(rela, d, "execution", interaction["execution"]),
         true <- target?(v, interaction) and v["execution"] == interaction["execution"],
         true <- e.environment == interaction["environment"],
         true <- runtime?(e.sender, execution["machine"], interaction["turn"]),
         :ok <- evidence(v) do
      {:ok,
       v
       |> Map.put("environment", e.environment)
       |> Map.put("writer", "runtime@" <> execution["machine"])}
    else
      false -> {:error, :receipt_authority}
      error -> error
    end
  end

  defp operation(_, _, _, _, _), do: {:error, :protected_operation_required}

  defp replay_payload(rela, d, role, values) do
    case fetch(rela, d, role, key(role, values)) do
      {:error, :not_found} ->
        :ok

      {:ok, existing} ->
        if Map.drop(existing, ["key", "recorded_at", "recorded_position"]) == values,
          do: :ok,
          else: {:error, :immutable_conflict}

      error ->
        error
    end
  end

  defp capable(execution) do
    if Enum.all?(
         ~w(queued_input durable_accept_query consumption_evidence),
         &(execution[&1] == true)
       ),
       do: :ok,
       else: {:error, :unsupported}
  end

  defp evidence(%{"stage" => "acknowledged"} = v) do
    if filled?(v["admission_id"]) and filled?(v["consumption_id"]),
      do: :ok,
      else: {:error, :consumption_evidence_required}
  end

  defp evidence(%{"stage" => "delivered"} = v) do
    if filled?(v["admission_id"]), do: :ok, else: {:error, :admission_evidence_required}
  end

  defp evidence(v) do
    if filled?(v["reason"]), do: :ok, else: {:error, :reason_required}
  end

  # Restricted to the exact turn endpoint or its owning machine's reconciler.
  defp runtime?(sender, machine, turn)
       when is_binary(machine) and is_binary(sender) and is_binary(turn),
       do: sender == "runtime@" <> machine or sender == "runtime@" <> machine <> "/" <> turn

  defp runtime?(_, _, _), do: false

  defp target?(a, b), do: Enum.all?(~w(worker turn attempt), &(a[&1] == b[&1]))

  defp shape(values, required, optional) do
    cond do
      Map.keys(values) -- (required ++ optional) != [] ->
        {:error, :unknown_fields}

      Enum.any?(required, &(not filled?(values[&1]))) ->
        {:error, :required_fields}

      Enum.any?(values, fn {slot, v} ->
        if slot in ~w(queued_input durable_accept_query consumption_evidence),
          do: not is_boolean(v),
          else: not is_binary(v)
      end) ->
        {:error, :invalid_fields}

      true ->
        :ok
    end
  end

  defp filled?(v), do: is_boolean(v) or (is_binary(v) and String.trim(v) != "")

  defp immutable(rela, d, role, values, next_position) do
    key = key(role, values)
    mapping = get_in(d, ["guidance", role, "fields"])

    values =
      values
      |> Map.put("recorded_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("recorded_position", next_position.())

    props = Map.new(values, fn {k, v} -> {Map.fetch!(mapping, k), v} end)
    spec = Description.kind(d, get_in(d, ["guidance", role, "kind"]))

    with :ok <- Description.check(spec, props, :create) do
      # No preflight read/check_create: the backend create is the identity claim.
      case Rela.create(rela, spec["plural"], key, props, %{}) do
        {:ok, []} ->
          Rela.get(rela, spec["plural"], key)

        {:error, :exists} ->
          compare(rela, spec["plural"], key, props, [
            mapping["recorded_at"],
            mapping["recorded_position"]
          ])

        {:ok, warnings} ->
          {:error, {:stored_with_warnings, warnings}}

        error ->
          error
      end
    end
  end

  defp compare(rela, plural, key, props, generated) do
    with {:ok, fact} <- Rela.get(rela, plural, key) do
      if Map.drop(fact.properties, generated) == Map.drop(props, generated),
        do: {:ok, fact},
        else: {:error, :immutable_conflict}
    end
  end

  defp key("execution", v), do: identity(["execution", v["environment"], v["turn"], v["attempt"]])

  defp key("interaction", v),
    do: identity(["interaction", v["environment"], v["actor"], v["client_key"]])

  defp key("receipt", v),
    do: identity(["receipt", v["environment"], v["interaction"], v["evidence_id"]])

  # Length-delimited JSON tuple; digest is an index, complete values are compared.
  defp identity(parts), do: "GI-" <> digest(JSON.encode!(parts))
  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp fetch(rela, d, role, key) do
    with {:ok, fact} <- Rela.get(rela, plural(d, role), key), do: {:ok, decode(d, role, fact)}
  end

  defp plural(d, role), do: kind_plural(d, get_in(d, ["guidance", role, "kind"]))
  defp kind_plural(d, kind), do: get_in(d, ["entities", kind, "plural"])

  defp decode(d, role, fact) do
    fields = get_in(d, ["guidance", role, "fields"])

    for {slot, name} <- fields,
        Map.has_key?(fact.properties, name),
        into: %{"key" => fact.key},
        do: {slot, fact.properties[name]}
  end

  defp view(rela, d, "interaction", fact) do
    interaction = decode(d, "interaction", fact)

    with true <- interaction["environment"] == AtlasBus.environment(),
         {:ok, facts} <- Rela.list(rela, plural(d, "receipt")) do
      receipts =
        facts
        |> Enum.map(&decode(d, "receipt", &1))
        |> Enum.filter(
          &(&1["interaction"] == fact.key and &1["environment"] == interaction["environment"])
        )
        |> Enum.sort_by(& &1["recorded_position"])

      {:ok, Map.merge(interaction, %{"receipts" => receipts, "projection" => project(receipts)})}
    else
      false -> {:error, :wrong_environment}
      error -> error
    end
  end

  defp view(_, d, role, fact) do
    value = decode(d, role, fact)

    if value["environment"] == AtlasBus.environment(),
      do: {:ok, value},
      else: {:error, :wrong_environment}
  end

  @doc "Last proven stage and independent uncertainty/closure evidence; replay never regresses proof."
  def project(receipts) do
    acknowledged = Enum.filter(receipts, &(&1["stage"] == "acknowledged"))
    delivered = Enum.filter(receipts, &(&1["stage"] == "delivered"))
    admissions = (acknowledged ++ delivered) |> Enum.map(& &1["admission_id"]) |> Enum.uniq()

    stage =
      cond do
        acknowledged != [] -> "acknowledged"
        delivered != [] -> "delivered"
        true -> "queued"
      end

    # Conflicting admission identities are evidence of ambiguity, never silently selected.
    uncertain = Enum.any?(receipts, &(&1["stage"] == "uncertain")) or length(admissions) > 1

    closures =
      receipts
      |> Enum.map(& &1["stage"])
      |> Enum.filter(&(&1 in ~w(stale unsupported rejected)))
      |> Enum.uniq()
      |> Enum.sort()

    %{"proven" => stage, "uncertain" => uncertain, "closures" => closures}
  end
end
