defmodule AtlasBFF.Wire do
  @moduledoc """
  Data-only wire descriptors, shared by compile-time validation and protocol targets.

  A descriptor names a channel, direction (`request`, `push`, `stream`), an optional
  request envelope and its replies. Envelopes declare `select` literal string fields,
  `present`/`absent` discriminator fields, and `required`/`optional` field types.
  Reply effects are `complete`, `progress`, `error`, or `terminal`. `requires` names
  earlier replies in the same exchange (e.g. a greeting before an initial page).
  Streaming exchanges require an explicit adapter; they have no inferred completion.
  No predicate, permission, replay or workflow policy is executable here.
  """

  def validate!(schema) do
    wires = Map.get(schema, :protocol, [])
    names = Enum.map(wires, & &1.name)
    ensure!(length(names) == length(Enum.uniq(names)), "duplicate wire descriptor")

    for wire <- wires do
      ensure!(identifier?(wire.name) and identifier?(wire.channel), "invalid wire name/channel")

      ensure!(
        Map.keys(wire) -- [:name, :channel, :direction, :request, :replies] == [],
        "unknown wire metadata"
      )

      ensure!(wire.direction in [:request, :push, :stream], "invalid wire direction")
      ensure!(wire.replies != [], "wire replies are incomplete")

      if wire.direction != :push do
        ensure!(
          Map.keys(wire.request) -- [:select, :required, :optional] == [],
          "unknown request metadata"
        )

        envelope!(wire.request)
      end

      reply_names = Enum.map(wire.replies, & &1.name)
      ensure!(length(reply_names) == length(Enum.uniq(reply_names)), "duplicate reply name")

      for reply <- wire.replies do
        ensure!(identifier?(reply.name), "invalid reply name")

        ensure!(
          Map.keys(reply) --
            [:name, :select, :present, :absent, :required, :optional, :effect, :requires] == [],
          "unknown reply metadata"
        )

        envelope!(reply)
        ensure!(reply.effect in [:complete, :progress, :error, :terminal], "invalid reply effect")
        ensure!(Map.get(reply, :requires, []) -- reply_names == [], "unknown required reply")

        for prerequisite <- Map.get(reply, :requires, []) do
          prior = Enum.find(wire.replies, &(&1.name == prerequisite))

          ensure!(
            prior.effect == :progress and Map.get(prior, :requires, []) == [],
            "invalid reply prerequisite"
          )
        end

        ensure!(reply.name not in Map.get(reply, :requires, []), "self-dependent reply")
      end

      if wire.direction == :request,
        do: ensure!(Enum.any?(wire.replies, &(&1.effect == :complete)), "no completion reply")

      disjoint!(wire.replies)

      pushes =
        for w <- wires, w.channel == wire.channel and w.direction == :push, r <- w.replies, do: r

      if wire.direction != :push, do: disjoint!(Enum.uniq(wire.replies ++ pushes))
    end

    for channel <- Enum.uniq(Enum.map(wires, & &1.channel)) do
      disjoint!(
        for w <- wires, w.channel == channel and w.direction == :push, r <- w.replies, do: r
      )
    end

    if wires != [] do
      for endpoint <- schema.endpoints do
        wire = Enum.find(wires, &(&1.name == endpoint[:wire]))
        ensure!(wire != nil, "unclassified endpoint #{endpoint.name}")

        selectors = if wire.direction == :push, do: wire.replies, else: [wire.request]

        ensure!(
          Enum.all?(selectors, &(&1.select["op"] == to_string(endpoint.call))),
          "endpoint wire call mismatch"
        )

        available =
          wire.replies ++
            for w <- wires,
                w.channel == wire.channel and w.direction == :push,
                r <- w.replies,
                do: r

        for reply <- Map.get(endpoint, :replies, []) do
          ensure!(
            Enum.any?(available, &(&1.name == reply.name)),
            "unclassified endpoint reply #{reply.name}"
          )
        end
      end
    end

    :ok
  end

  defp identifier?(value), do: is_atom(value) and value not in [nil, true, false]

  defp envelope!(envelope) do
    select = Map.get(envelope, :select, %{})
    present = Map.get(envelope, :present, [])
    absent = Map.get(envelope, :absent, [])
    ensure!(is_map(select) and is_binary(select["op"]), "selector needs an op")

    ensure!(
      Enum.all?(select, fn {k, v} -> is_binary(k) and is_binary(v) end),
      "invalid selector literal"
    )

    ensure!(
      is_list(present) and is_list(absent) and Enum.all?(present ++ absent, &is_binary/1),
      "invalid presence selector"
    )

    ensure!(Enum.all?(Map.keys(select) ++ present, &(&1 not in absent)), "contradictory selector")
    required = Map.get(envelope, :required, %{})
    optional = Map.get(envelope, :optional, %{})
    ensure!(is_map(required) and is_map(optional), "invalid envelope fields")
    ensure!(Enum.all?(Map.keys(required), &(&1 not in absent)), "absent required field")

    ensure!(
      Enum.all?(Map.keys(required), &(not Map.has_key?(optional, &1))),
      "duplicate envelope field"
    )

    for key <- [:required, :optional], {name, type} <- Map.get(envelope, key, %{}) do
      ensure!(is_binary(name) and valid_type?(type), "invalid envelope field")
    end
  end

  defp valid_type?(type) when type in [:string, :integer, :boolean, :map, :list], do: true
  defp valid_type?({:map, type}), do: type in [:string, :integer, :boolean]
  defp valid_type?(_), do: false

  defp disjoint!([]), do: :ok

  defp disjoint!([head | tail]) do
    for other <- tail, do: ensure!(not overlap?(head, other), "overlapping reply selectors")
    disjoint!(tail)
  end

  defp overlap?(a, b) do
    literals_disagree =
      Enum.any?(a.select, fn {k, v} -> Map.has_key?(b.select, k) and b.select[k] != v end)

    a_present = Map.keys(a.select) ++ Map.get(a, :present, [])
    b_present = Map.keys(b.select) ++ Map.get(b, :present, [])

    literals_disagree == false and
      Enum.all?(a_present, &(&1 not in Map.get(b, :absent, []))) and
      Enum.all?(b_present, &(&1 not in Map.get(a, :absent, [])))
  end

  defp ensure!(true, _), do: :ok
  defp ensure!(false, why), do: raise(ArgumentError, why)

  def descriptor!(wires, name, channel) do
    wire = Enum.find(wires, &(&1.name == name)) || raise(ArgumentError, "unknown wire #{name}")

    ensure!(
      wire.channel == channel and wire.direction == :request,
      "not a request on this channel"
    )

    wire
  end

  def encode!(wire, props) do
    message = Map.new(props, fn {k, v} -> {to_string(k), v} end)

    known =
      Map.keys(Map.get(wire.request, :required, %{})) ++
        Map.keys(Map.get(wire.request, :optional, %{}))

    ensure!(Map.keys(message) -- known == [], "unknown envelope fields")

    message =
      message
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
      |> Map.merge(wire.request.select)

    check!(wire.request, message)
    message
  end

  def classify(wires, name, channel, message) when is_map(message) do
    wire = descriptor!(wires, name, channel)

    pushes =
      for w <- wires, w.channel == channel and w.direction == :push, reply <- w.replies, do: reply

    case Enum.find(wire.replies ++ pushes, &matches?(&1, message)) do
      nil ->
        :ignore

      reply ->
        try do
          check!(reply, message)
          {:reply, reply}
        rescue
          e in ArgumentError -> {:invalid, Exception.message(e)}
        end
    end
  end

  def classify(_, _, _, _), do: {:invalid, "expected an object"}

  defp matches?(selector, message) do
    Enum.all?(selector.select, fn {k, v} -> message[k] == v end) and
      Enum.all?(Map.get(selector, :present, []), &Map.has_key?(message, &1)) and
      Enum.all?(Map.get(selector, :absent, []), &(not Map.has_key?(message, &1)))
  end

  defp check!(envelope, message) do
    for {key, type} <- Map.get(envelope, :required, %{}) do
      ensure!(
        Map.has_key?(message, key) and typed?(message[key], type),
        "missing or invalid #{key}"
      )
    end

    for {key, type} <- Map.get(envelope, :optional, %{}),
        Map.has_key?(message, key) and message[key] != nil do
      ensure!(typed?(message[key], type), "invalid #{key}")
    end
  end

  defp typed?(v, :string), do: is_binary(v)
  defp typed?(v, :integer), do: is_integer(v)
  defp typed?(v, :boolean), do: is_boolean(v)
  defp typed?(v, :map), do: is_map(v)
  defp typed?(v, :list), do: is_list(v)

  defp typed?(v, {:map, type}),
    do: is_map(v) and Enum.all?(v, fn {k, x} -> is_binary(k) and typed?(x, type) end)
end
