defmodule AtlasPlan.Owner do
  @moduledoc """
  The IS-Atlas-52 migration: every fact gets an owner. Run once on an environment whose
  rela already has the new description: an `agent` kind and the association
  `assigned_to` (from every assignable kind to a person or an agent, at most one).

  It reads rela directly, read-only, and writes only through Control, as a client that
  says it is the migration. Every write is one fact with the cause
  #{inspect("owner introduced")}:

  1. the agent `coordinator` (Coordinator), when there is none;
  2. every fact of a kind in `assigned_to`'s `from` (scenes, use cases, issues, pull
     requests today; read from rela's description, so a kind added there is included)
     that has no owner yet gets `assigned_to` coordinator.

  Since IS-Atlas-78 `assigned_to` starts at the Assignment, so the facts it reads are the
  Assignments, and an Assignment without an owner gets the coordinator.

  A dry run reads and prints the steps, and writes nothing. A second run finds nothing
  left to do: a fact that has an owner keeps it.
  """

  @cause "owner introduced"
  @relation "assigned_to"
  @owner %{
    "kind" => "agent",
    "plural" => "agents",
    "key" => "coordinator",
    "name" => "Coordinator"
  }

  @doc """
  The steps for what rela holds now. `schema` is rela's description (`/_schema`); `facts`
  is `%{plural => [fact]}` as rela's API gives facts (`"id"`, `"relations"`), for the
  plurals of `assigned_to`'s `from` kinds and for agents.
  """
  def steps(schema, facts) do
    agents = Enum.map(facts[@owner["plural"]] || [], & &1["id"])
    agent = if @owner["key"] in agents, do: [], else: [{:agent, @owner["name"]}]

    assign =
      for plural <- plurals(schema),
          fact <- Enum.sort_by(facts[plural] || [], & &1["id"]),
          ((fact["relations"] || %{})[@relation] || []) == [],
          do: {:assign, fact["id"], @owner["key"]}

    agent ++ assign
  end

  @doc "The plurals of the kinds `assigned_to` starts at, from rela's description."
  def plurals(schema) do
    for kind <- get_in(schema, ["relations", @relation, "from"]) || [],
        plural = get_in(schema, ["entities", kind, "plural"]),
        do: plural
  end

  @doc "One step as a line of text."
  def line({:agent, name}), do: "agent    #{String.downcase(name)} (#{name})"
  def line({:assign, key, owner}), do: "assign   #{key}  #{@relation} #{owner}"

  @doc """
  Read rela (`url`, its API base) and run the steps through `client` (connected as the
  migration). `opts`: `dry_run`, `say` (prints a line).
  """
  def run(client, url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with {:ok, schema} <- get(url, "_schema"),
         :ok <- described(schema),
         {:ok, facts} <- read(url, plurals(schema) ++ [@owner["plural"]]) do
      steps = steps(schema, facts)
      say.("IS-Atlas-52 migration: #{length(steps)} steps; cause: #{@cause}")
      Enum.each(steps, &say.(line(&1)))

      if Keyword.get(opts, :dry_run, false) do
        say.("Dry run: nothing was written.")
        {:ok, %{steps: steps, written: 0}}
      else
        write(client, steps, say)
      end
    end
  end

  defp described(schema) do
    cond do
      get_in(schema, ["relations", @relation]) == nil ->
        {:error, "rela has no #{@relation}: does it run the new description?"}

      get_in(schema, ["entities", @owner["kind"]]) == nil ->
        {:error, "rela has no #{@owner["kind"]} kind: does it run the new description?"}

      true ->
        :ok
    end
  end

  defp write(client, steps, say) do
    Enum.reduce_while(steps, {:ok, 0}, fn step, {:ok, n} ->
      case apply_step(client, step) do
        {:ok, _} ->
          say.("done     " <> line(step))
          {:cont, {:ok, n + 1}}

        {:refused, reasons} ->
          {:halt, {:error, "#{line(step)}: refused: #{Enum.join(reasons, "; ")}"}}

        {:error, text} ->
          {:halt, {:error, "#{line(step)}: #{text}"}}
      end
    end)
    |> case do
      {:ok, n} ->
        say.("Done: #{n} of #{length(steps)} steps written.")
        {:ok, %{steps: steps, written: n}}

      error ->
        error
    end
  end

  defp apply_step(client, {:agent, name}),
    do: AtlasAgent.put(client, @owner["kind"], %{"name" => name}, nil, @cause)

  defp apply_step(client, {:assign, key, owner}),
    do: AtlasAgent.set(client, key, %{@relation => owner}, @cause)

  @doc false
  def read(url, plurals) do
    Enum.reduce_while(plurals, {:ok, %{}}, fn plural, {:ok, acc} ->
      case list(url, plural, 1, []) do
        {:ok, facts} -> {:cont, {:ok, Map.put(acc, plural, facts)}}
        {:error, text} -> {:halt, {:error, text}}
      end
    end)
  end

  defp list(url, plural, page, acc) do
    case get(url, "#{plural}?per_page=100&page=#{page}") do
      {:ok, %{"data" => data, "meta" => meta}} ->
        acc = acc ++ data
        if meta["has_more"], do: list(url, plural, page + 1, acc), else: {:ok, acc}

      {:ok, other} ->
        {:error, "rela answered #{plural} with #{inspect(other) |> String.slice(0, 200)}"}

      error ->
        error
    end
  end

  @doc false
  def get(url, path) do
    address = String.to_charlist("#{url}/#{path}")

    case :httpc.request(:get, {address, [{~c"accept", ~c"application/json"}]}, [timeout: 10_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, JSON.decode!(body)}
      {:ok, {{_, status, _}, _, _}} -> {:error, "rela at #{url} answered #{status} to #{path}"}
      other -> {:error, "rela at #{url} did not answer #{path}: #{inspect(other)}"}
    end
  end
end
