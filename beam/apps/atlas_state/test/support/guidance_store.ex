defmodule AtlasState.GuidanceStore do
  @moduledoc "Private disk store with atomic identity claims and a commit barrier."
  @behaviour AtlasState.Rela
  def start(path, description),
    do: Agent.start_link(fn -> %{path: path, description: description, barrier: nil} end)

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
    Agent.get(pid, fn s ->
      case get_in(facts(s), [plural, key]) do
        nil -> {:error, :not_found}
        props -> {:ok, wire(key, props)}
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
  def change(_, _, _, _, _, _), do: {:error, {:invalid, ["immutable"]}}
  @impl true
  def delete(_, _, _, _), do: {:error, {:invalid, ["retained"]}}
end
