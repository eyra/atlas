defmodule AtlasState.FakeRela do
  @moduledoc """
  rela in memory, with the current release's habits: invalid values are stored with
  warnings, a second create answers "exists", a deleted id stays reserved, versions
  are checked when given. Its kinds are made up on purpose: State must not care.
  """
  @behaviour AtlasState.Rela

  def description do
    %{
      "entities" => %{
        "widget" => %{
          "plural" => "widgets",
          "primary" => "title",
          "id_type" => "manual",
          "id_prefixes" => ["W-"],
          "properties" => %{
            "title" => %{"type" => "string", "required" => true},
            "shade" => %{"type" => "shade", "values" => ["light", "dark"]},
            "done" => %{"type" => "boolean"}
          }
        },
        "part" => %{"plural" => "parts", "properties" => %{"title" => %{"type" => "string"}}}
      },
      "relations" => %{"of_widget" => %{"from" => ["part"], "to" => ["widget"]}}
    }
  end

  def start do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{facts: %{}, reserved: MapSet.new(), up: true, links: %{}, n: 0}
      end)

    pid
  end

  def down(pid), do: Agent.update(pid, &%{&1 | up: false})
  def up(pid), do: Agent.update(pid, &%{&1 | up: true})
  def facts(pid), do: Agent.get(pid, & &1.facts)
  def link(pid, part, widget), do: Agent.update(pid, &put_in(&1, [:links, part], widget))

  @doc "Change a fact behind State's back, as another writer would."
  def poke(pid, key, values) do
    Agent.update(pid, fn s ->
      {props, n} = s.facts[key]
      %{s | facts: Map.put(s.facts, key, {Map.merge(props, values), n + 100})}
    end)
  end

  defp call(pid, fun) do
    Agent.get_and_update(pid, fn s ->
      if s.up, do: fun.(s), else: {{:error, :unavailable}, s}
    end)
  end

  @impl true
  def description(pid), do: call(pid, &{{:ok, description()}, &1})

  @impl true
  def list(pid, _plural) do
    call(pid, fn s ->
      {{:ok, for({k, {p, _}} <- Enum.sort(s.facts), do: %{key: k, properties: p, version: nil})},
       s}
    end)
  end

  @impl true
  def get(pid, _plural, key) do
    call(pid, fn s ->
      case s.facts[key] do
        {p, n} -> {{:ok, %{key: key, properties: p, version: "v#{n}"}}, s}
        nil -> {{:error, :not_found}, s}
      end
    end)
  end

  @impl true
  def incoming(pid, _plural, key, "of_widget") do
    call(pid, fn s -> {{:ok, for({part, ^key} <- s.links, do: part)}, s} end)
  end

  @impl true
  def check_create(pid, _plural, _key, props), do: call(pid, &{{:ok, warnings(props)}, &1})

  @impl true
  def create(pid, _plural, key, props) do
    call(pid, fn s ->
      if Map.has_key?(s.facts, key) or key in s.reserved do
        {{:error, :exists}, s}
      else
        {{:ok, warnings(props)}, %{s | facts: Map.put(s.facts, key, {props, s.n}), n: s.n + 1}}
      end
    end)
  end

  @impl true
  def change(pid, _plural, key, props, version) do
    call(pid, fn s ->
      case s.facts[key] do
        nil ->
          {{:error, :not_found}, s}

        {old, n} ->
          if stale?(version, n),
            do: {{:error, :version_mismatch}, s},
            else: changed(s, key, old, props)
      end
    end)
  end

  defp changed(s, key, old, props) do
    new = old |> Map.merge(props) |> Map.reject(fn {_, v} -> is_nil(v) end)
    {{:ok, warnings(new)}, %{s | facts: Map.put(s.facts, key, {new, s.n}), n: s.n + 1}}
  end

  @impl true
  def delete(pid, _plural, key, version) do
    call(pid, fn s ->
      case s.facts[key] do
        nil ->
          {{:error, :not_found}, s}

        {_, n} ->
          if stale?(version, n),
            do: {{:error, :version_mismatch}, s},
            else:
              {:ok, %{s | facts: Map.delete(s.facts, key), reserved: MapSet.put(s.reserved, key)}}
      end
    end)
  end

  defp stale?(nil, _n), do: false
  defp stale?(version, n), do: version != "v#{n}"

  defp warnings(props) do
    if Map.has_key?(props, "title"), do: [], else: ["/properties/title is required"]
  end
end
