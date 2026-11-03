defmodule AtlasState.Links do
  @moduledoc """
  The fact that set each link, on disk in State's data folder: when, by whom and why.

  A link in rela has no attributes; what State knows about it comes from the fact that
  set it. So when a stored fact names links (a create, or a change that sets or removes
  them), State records, per fact and relation, `%{"keys", "since", "by", "cause",
  "position"}`: the keys it points at afterwards (`[]` when the fact removed them), the
  moment and position State stored it, who sent it and why. Every entry is kept, newest
  last: the history of the link.

  A read answers the newest entry only while it still holds: when rela's links are the
  keys it recorded. A link someone set behind State's back has no origin.
  """

  def open(dir) do
    File.mkdir_p!(dir)
    file = dir |> Path.join("links.dets") |> String.to_charlist()
    {:ok, table} = :dets.open_file(make_ref(), file: file, type: :set)
    table
  end

  def close(table), do: :dets.close(table)

  @doc "Record that the fact `key` of `kind` now points at `keys` through `relation`."
  def record(table, kind, key, relation, keys, about) do
    entry = Map.put(about, "keys", Enum.sort(keys))

    :ok =
      :dets.insert(table, {{kind, key, relation}, history(table, kind, key, relation) ++ [entry]})

    (fn ->
       t0 = System.monotonic_time(:microsecond)
       r = :dets.sync(table)
       require Logger
       d = div(System.monotonic_time(:microsecond) - t0, 1000)
       if d >= 20, do: Logger.warning("DETS links sync #{d}ms")
       r
     end).()
  end

  @doc "Every entry for one link, oldest first."
  def history(table, kind, key, relation) do
    case :dets.lookup(table, {kind, key, relation}) do
      [{_, entries}] -> entries
      [] -> []
    end
  end

  @doc "All entries of a fact: `%{relation => entries}`."
  def all(table, kind, key) do
    table
    |> :dets.match({{kind, key, :"$1"}, :"$2"})
    |> Map.new(fn [relation, entries] -> {relation, entries} end)
  end

  @doc """
  The origin of each of a fact's links that still holds: `%{relation => entry}`. `links`
  are the fact's links as rela has them now; a relation with no link counts as `[]`.
  """
  def origins(table, kind, key, links) do
    for {relation, entries} <- all(table, kind, key),
        entry = List.last(entries),
        entry["keys"] == Enum.sort(links[relation] || []),
        into: %{},
        do: {relation, entry}
  end

  @doc "Forget a deleted fact's links."
  def forget(table, kind, key) do
    :ok = :dets.match_delete(table, {{kind, key, :_}, :_})

    (fn ->
       t0 = System.monotonic_time(:microsecond)
       r = :dets.sync(table)
       require Logger
       d = div(System.monotonic_time(:microsecond) - t0, 1000)
       if d >= 20, do: Logger.warning("DETS links sync #{d}ms")
       r
     end).()
  end
end
