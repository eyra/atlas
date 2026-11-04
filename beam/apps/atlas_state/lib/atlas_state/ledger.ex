defmodule AtlasState.Ledger do
  @moduledoc """
  What State answered to each fact id, and the environment's last position, on disk.

  A resent fact gets the answer recorded here, unchanged: the same "stored" with the
  same position, or the same "refused". So each id is stored once (rule 6) and
  answered every time (rule 7).
  """

  def open(dir) do
    File.mkdir_p!(dir)
    file = dir |> Path.join("ledger.dets") |> String.to_charlist()
    {:ok, table} = :dets.open_file(make_ref(), file: file, type: :set)
    table
  end

  def close(table), do: :dets.close(table)

  def answer(table, id) do
    case :dets.lookup(table, {:answer, id}) do
      [{_, answer}] -> answer
      [] -> nil
    end
  end

  def position(table) do
    case :dets.lookup(table, :position) do
      [{_, position}] -> position
      [] -> 0
    end
  end

  @doc "Record a stored fact under the next position; returns that position."
  def stored(table, id, content) do
    position = position(table) + 1

    :ok =
      :dets.insert(table, [{:position, position}, {{:answer, id}, {"stored", content, position}}])

    :ok = :dets.sync(table)
    position
  end

  def refused(table, id, content) do
    :ok = :dets.insert(table, {{:answer, id}, {"refused", content, nil}})
    :ok = :dets.sync(table)
  end
end
