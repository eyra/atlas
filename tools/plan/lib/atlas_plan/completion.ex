defmodule AtlasPlan.Completion do
  @moduledoc """
  The UC-Atlas-32 migration: completion becomes an association. Run once on an
  environment whose rela already has the new description (IS-Atlas-62): a `person` kind,
  `accepted_by` and `done_in`; the `completed` field and the `testing` stage gone.

  rela keeps the old `completed` values after the field left the description, but no
  longer lets anyone change them over its API. So this reads them from rela directly,
  read-only, and writes only through Control, as a client that says it is the migration
  (which may set `done_in`, marked `set_by: migration`). Every write is one fact with the
  cause #{inspect("completion becomes an association (UC-Atlas-32)")}:

  1. the person `melle` (Melle), when there is none;
  2. every scene and use case with `completed: true` and no `accepted_by` gets
     `accepted_by` melle: Melle accepted them before, as completed;
  3. every issue at stage `testing` moves to `development`;
  4. every issue with `completed: true` and no merged pull request of its own gets
     `done_in` the merged pull request that did it, from the history file
     (`tools/plan/done_in.json`). One the file does not name is listed, not linked.

  Then the old `completed` values are removed by rela's own garbage collection, with rela
  stopped (`bin/atlas migrate-completion` does that after a run that is not dry).

  A dry run reads and prints the steps, and writes nothing. A second run finds nothing
  left to do.
  """

  @cause "completion becomes an association (UC-Atlas-32)"
  @person %{"key" => "melle", "name" => "Melle"}
  @accepting [{"scene", "scenes"}, {"use_case", "use_cases"}]

  @doc """
  The steps for what rela holds now: `old` is `%{plural => [fact]}` as rela's API gives
  facts (`"id"`, `"properties"`, `"relations"`), for scenes, use_cases, issues,
  pull_requests and people. `done_in` maps an issue to the pull request URL that did it.
  Answers `{steps, unmapped}`: the steps in order, and the issues it cannot link.
  """
  def steps(old, done_in) do
    people = Enum.map(old["people"] || [], & &1["id"])
    person = if @person["key"] in people, do: [], else: [{:person, @person["name"]}]

    accept =
      for {_kind, plural} <- @accepting,
          fact <- Enum.sort_by(old[plural] || [], & &1["id"]),
          fact["properties"]["completed"] in [true, "true"],
          links(fact, "accepted_by") == [],
          do: {:accept, fact["id"], @person["key"]}

    issues = Enum.sort_by(old["issues"] || [], & &1["id"])

    stages =
      for fact <- issues,
          fact["properties"]["stage"] == "testing",
          do: {:stage, fact["id"], "development"}

    merged =
      for pr <- old["pull_requests"] || [],
          pr["properties"]["state"] == "merged",
          issue <- links(pr, "in_issue"),
          into: MapSet.new(),
          do: issue

    pr_keys = Map.new(old["pull_requests"] || [], &{&1["properties"]["url"], &1["id"]})

    lacking =
      for fact <- issues,
          fact["properties"]["completed"] in [true, "true"],
          fact["id"] not in merged,
          links(fact, "done_in") == [],
          do: fact["id"]

    {linked, unmapped} =
      Enum.split_with(lacking, fn key -> pr_keys[done_in[key]] != nil end)

    links = for key <- linked, do: {:done_in, key, pr_keys[done_in[key]]}
    {person ++ accept ++ stages ++ links, unmapped}
  end

  defp links(fact, relation), do: (fact["relations"] || %{})[relation] || []

  @doc "One step as a line of text."
  def line({:person, name}), do: "person   #{String.downcase(name)} (#{name})"
  def line({:accept, key, by}), do: "accept   #{key}  accepted_by #{by}"
  def line({:stage, key, stage}), do: "stage    #{key}  testing → #{stage}"
  def line({:done_in, key, pr}), do: "done_in  #{key}  #{pr}"

  @doc """
  Read rela (`url`, its API base) and run the steps through `client` (connected as the
  migration). `opts`: `dry_run`, `say` (prints a line), `done_in` (the history map).
  """
  def run(client, url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with {:ok, old} <- read(url) do
      {steps, unmapped} = steps(old, Keyword.get(opts, :done_in, %{}))

      say.("UC-Atlas-32 migration: #{length(steps)} steps; cause: #{@cause}")
      Enum.each(steps, &say.(line(&1)))

      for key <- unmapped,
          do:
            say.(
              "not linked: #{key} is completed without a merged pull request of its own, " <>
                "and done_in.json names none"
            )

      cond do
        Keyword.get(opts, :dry_run, false) ->
          say.("Dry run: nothing was written.")
          {:ok, %{steps: steps, unmapped: unmapped, written: 0}}

        true ->
          write(client, steps, unmapped, say)
      end
    end
  end

  defp write(client, steps, unmapped, say) do
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
        {:ok, %{steps: steps, unmapped: unmapped, written: n}}

      error ->
        error
    end
  end

  defp apply_step(client, {:person, name}),
    do: AtlasAgent.put(client, "person", %{"name" => name}, nil, @cause)

  defp apply_step(client, {:accept, key, by}),
    do: AtlasAgent.set(client, key, %{"accepted_by" => by}, @cause)

  defp apply_step(client, {:stage, key, stage}),
    do: AtlasAgent.set(client, key, %{"stage" => stage}, @cause)

  defp apply_step(client, {:done_in, key, pr}),
    do: AtlasAgent.set(client, key, %{"done_in" => pr}, @cause)

  @plurals ~w(scenes use_cases issues pull_requests people)

  @doc "What rela holds, read-only: `%{plural => [fact]}`."
  def read(url) do
    Enum.reduce_while(@plurals, {:ok, %{}}, fn plural, {:ok, acc} ->
      case list(url, plural, 1, []) do
        {:ok, facts} -> {:cont, {:ok, Map.put(acc, plural, facts)}}
        {:error, text} -> {:halt, {:error, text}}
      end
    end)
  end

  defp list(url, plural, page, acc) do
    address = String.to_charlist("#{url}/#{plural}?per_page=100&page=#{page}")

    case :httpc.request(:get, {address, [{~c"accept", ~c"application/json"}]}, [timeout: 10_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        %{"data" => data, "meta" => meta} = JSON.decode!(body)
        acc = acc ++ data
        if meta["has_more"], do: list(url, plural, page + 1, acc), else: {:ok, acc}

      {:ok, {{_, 404, _}, _, _}} ->
        {:error, "rela at #{url} has no #{plural}: does it run the new description?"}

      other ->
        {:error, "rela at #{url} did not answer #{plural}: #{inspect(other)}"}
    end
  end
end
