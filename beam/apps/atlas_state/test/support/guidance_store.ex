defmodule AtlasState.GuidanceStore do
  @moduledoc "Private disk store with atomic identity claims and a commit barrier."
  @behaviour AtlasState.Rela
  def start(path, description),
    do:
      Agent.start_link(fn ->
        %{path: path, description: description, barrier: nil, faults: %{}, mutations: []}
      end)

  def fail_next_get(pid, plural, key, reason),
    do: Agent.update(pid, &%{&1 | faults: Map.put(&1.faults, {plural, key}, reason)})

  def mutations(pid), do: Agent.get(pid, & &1.mutations)

  def barrier(pid, owner), do: Agent.update(pid, &%{&1 | barrier: owner})

  defp facts(s) do
    case File.read(s.path) do
      {:ok, json} -> JSON.decode!(json)
      {:error, :enoent} -> %{}
    end
  end

  defp wire(key, props),
    do: %{key: key, properties: props["properties"], links: props["links"], version: nil}

  @impl true
  def description(pid), do: Agent.get(pid, &{:ok, &1.description})
  @impl true
  def get(pid, plural, key) do
    Agent.get_and_update(pid, fn s ->
      case Map.pop(s.faults, {plural, key}) do
        {nil, _} ->
          result =
            case get_in(facts(s), [plural, key]) do
              nil -> {:error, :not_found}
              props -> {:ok, wire(key, props)}
            end

          {result, s}

        {reason, faults} ->
          {{:error, reason}, %{s | faults: faults}}
      end
    end)
  end

  @impl true
  def list(pid, plural),
    do:
      Agent.get(pid, fn s ->
        {:ok, Enum.map(facts(s)[plural] || %{}, fn {k, v} -> wire(k, v) end)}
      end)

  @impl true
  def create(pid, plural, key, props, targets) do
    Agent.get_and_update(pid, fn s ->
      all = facts(s)
      own = all[plural] || %{}

      if Map.has_key?(own, key) do
        {{:error, :exists}, s}
      else
        links = Map.new(targets, fn {name, {_, keys}} -> {name, keys} end)
        own = Map.put(own, key, %{"properties" => props, "links" => links})
        File.write!(s.path, JSON.encode!(Map.put(all, plural, own)), [:sync])

        if s.barrier do
          send(s.barrier, {:committed, self(), key})

          receive do
            :release_commit -> :ok
          end
        end

        {{:ok, []}, %{s | barrier: nil}}
      end
    end)
  end

  @impl true
  def incoming(_, _, _, _), do: {:ok, []}
  @impl true
  def check_create(_, _, _, _, _), do: {:ok, []}
  @impl true
  def change(pid, plural, key, props, _version, targets) do
    Agent.get_and_update(pid, fn s ->
      all = facts(s)

      case get_in(all, [plural, key]) do
        nil ->
          {{:error, :not_found}, s}

        old ->
          links =
            Enum.reduce(targets, old["links"], fn {name, {_, keys}}, acc ->
              Map.put(acc, name, keys)
            end)

          updated = %{old | "properties" => Map.merge(old["properties"], props), "links" => links}
          File.write!(s.path, JSON.encode!(put_in(all, [plural, key], updated)), [:sync])
          {{:ok, []}, %{s | mutations: [{:change, plural, key} | s.mutations]}}
      end
    end)
  end

  @impl true
  def delete(pid, plural, key, _version) do
    Agent.get_and_update(pid, fn s ->
      all = facts(s)

      if get_in(all, [plural, key]) do
        File.write!(s.path, JSON.encode!(Map.update!(all, plural, &Map.delete(&1, key))), [:sync])
        {:ok, %{s | mutations: [{:delete, plural, key} | s.mutations]}}
      else
        {{:error, :not_found}, s}
      end
    end)
  end
end
