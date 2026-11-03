defmodule AtlasPlan.Assignment do
  @moduledoc """
  The IS-Atlas-78 migration (d-0022): every assignable fact gets its Assignment, and its
  owner moves there. Before, a fact held `assigned_to` itself and `expected` was its own
  field; now both are its Assignment's (`AS-` and its key), made and deleted with it.

  It reads rela directly and writes through Control, as a client that says it is the
  migration, with one exception: the old links, which the new description no longer
  describes, are removed in rela itself, as `rela migrate gc` removes the old fields.

  For every fact of a kind the `assignment` association starts at (the kinds
  `assigned_to` started at, on the old description):

  1. `make`: its Assignment, when there is none (`atlas put assignment --of <key>`);
  2. `link`: the fact's `assignment` to it;
  3. `assign`: the Assignment's `assigned_to`, to the fact's old owner, with a cause that
     keeps when, by whom and why the old link was set (Control showed that fact; the
     migration reads it before rela and the core move to the new description);
  4. `unlink`: the fact's old `assigned_to`, in rela.

  `expected` is not copied: Flow alone writes it, and writes it on the Assignment again
  within its first round, by the same rule. A dry run reads and prints the steps and
  writes nothing; a second run finds nothing left to do.
  """

  @cause "assignment introduced (IS-Atlas-78)"
  @component "assignment"
  @owner "assigned_to"
  @owner_label "Assigned to"

  @external_resource Path.expand("../../../../rela/atlas.json", __DIR__)
  @template @external_resource
            |> File.read!()
            |> JSON.decode!()
            |> get_in(["relations", @component, "component", "key"])

  @doc "The key of the Assignment of the fact with `key`, as State makes it."
  def key_of(key), do: String.replace(@template, "{key}", key)

  @doc """
  The kinds whose facts get an Assignment: those the association starts at, or, on the
  old description, those `assigned_to` started at. From rela's description.
  """
  def kinds(schema) do
    get_in(schema, ["relations", @component, "from"]) ||
      get_in(schema, ["relations", @owner, "from"]) || []
  end

  @doc "The plurals of `kinds/1`, and of the Assignment kind when rela describes it."
  def plurals(schema) do
    for kind <- kinds(schema) ++ [@component],
        plural = get_in(schema, ["entities", kind, "plural"]),
        do: plural
  end

  @doc """
  The steps for what rela holds now. `facts` are the facts of `kinds/1`, `assignments`
  the Assignments, as rela's API gives them (`"id"`, `"properties"`, `"relations"`);
  `origins` is `%{key => %{"since", "by", "cause"}}`: the fact that set each old owner.
  """
  def steps(facts, assignments, origins) do
    by_of = Map.new(assignments, &{get_in(&1, ["properties", "of"]), &1})

    Enum.flat_map(Enum.sort_by(facts, & &1["id"]), fn fact ->
      key = fact["id"]
      part = by_of[key]
      part_key = (part && part["id"]) || key_of(key)
      old = links(fact, @owner)

      make = if part, do: [], else: [{:make, key, part_key}]
      link = if links(fact, @component) == [part_key], do: [], else: [{:link, key, part_key}]

      assign =
        if old != [] and links(part, @owner) == [],
          do: [{:assign, part_key, hd(old), cause(key, origins[key])}],
          else: []

      unlink = if old == [], do: [], else: [{:unlink, key, hd(old)}]
      make ++ link ++ assign ++ unlink
    end)
  end

  defp links(nil, _relation), do: []
  defp links(fact, relation), do: get_in(fact, ["relations", relation]) || []

  @doc "The cause of the moved owner: this migration's, with the fact that set the old link."
  def cause(key, nil), do: "#{@cause}; moved from #{key}, which did not say who set it"

  def cause(key, origin) do
    set =
      [
        origin["since"] && "set #{origin["since"]}",
        origin["by"] && "by #{origin["by"]}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    why = if origin["cause"] in [nil, ""], do: "", else: ": #{origin["cause"]}"
    "#{@cause}; moved from #{key}, #{set}#{why}"
  end

  @doc "One step as a line of text."
  def line({:make, key, part}), do: "make     #{part} (#{@component} of #{key})"
  def line({:link, key, part}), do: "link     #{key}  #{@component} #{part}"
  def line({:assign, part, owner, cause}), do: "assign   #{part}  #{@owner} #{owner}  (#{cause})"
  def line({:unlink, key, owner}), do: "unlink   #{key}  old #{@owner} #{owner}"

  @doc """
  Read rela (`url`, its API base) and run the steps through `client` (connected as the
  migration). `opts`: `dry_run`; `origins` (a file of the old owners' origins: read from
  it, or, when it is not there, through Control and kept in it, before anything else);
  `say` (prints a line).
  """
  def run(client, url, opts \\ []) do
    say = Keyword.get(opts, :say, &IO.puts/1)

    with {:ok, schema} <- get(url, "_schema"),
         {:ok, facts} <- read(url, plurals(schema)),
         items = Enum.flat_map(item_plurals(schema), &(facts[&1] || [])),
         {:ok, origins} <- origins(client, items, opts[:origins]) do
      plural = get_in(schema, ["entities", @component, "plural"])
      steps = steps(items, facts[plural] || [], origins)
      say.("IS-Atlas-78 migration: #{length(steps)} steps; cause: #{@cause}")
      Enum.each(steps, &say.(line(&1)))

      cond do
        Keyword.get(opts, :dry_run, false) ->
          say.("Dry run: nothing was written.")
          {:ok, %{steps: steps, written: 0}}

        Keyword.get(opts, :read_only, false) ->
          say.("Origins kept; nothing was written yet.")
          {:ok, %{steps: steps, written: 0}}

        get_in(schema, ["entities", @component]) == nil ->
          {:error, "rela has no #{@component} kind: does it run the new description?"}

        true ->
          write(client, url, schema, steps, say)
      end
    end
  end

  defp item_plurals(schema) do
    for kind <- kinds(schema),
        plural = get_in(schema, ["entities", kind, "plural"]),
        do: plural
  end

  # The fact that set each old owner, as Control shows it on the fact's page (only while
  # the core runs the old description); kept in `file`, so a run on the new one has them.
  defp origins(client, items, file) do
    case file && File.read(file) do
      {:ok, json} ->
        {:ok, JSON.decode!(json)}

      _ ->
        found =
          for item <- items,
              links(item, @owner) != [],
              {:ok, %{"origins" => %{@owner_label => origin}}} <-
                [AtlasAgent.get(client, item["id"])],
              into: %{},
              do: {item["id"], Map.take(origin, ["since", "by", "cause"])}

        if file, do: File.write!(file, JSON.encode!(found))
        {:ok, found}
    end
  end

  defp write(client, url, schema, steps, say) do
    Enum.reduce_while(steps, {:ok, 0}, fn step, {:ok, n} ->
      case apply_step(client, url, schema, step) do
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

  defp apply_step(client, _url, _schema, {:make, key, _part}),
    do: AtlasAgent.put(client, @component, %{"of" => key}, nil, @cause)

  defp apply_step(client, _url, _schema, {:link, key, part}),
    do: AtlasAgent.set(client, key, %{@component => part}, @cause)

  defp apply_step(client, _url, _schema, {:assign, part, owner, cause}),
    do: AtlasAgent.set(client, part, %{@owner => owner}, cause)

  # The old link is no longer described, so Control does not set it: rela removes it.
  defp apply_step(_client, url, schema, {:unlink, key, _owner}) do
    plural =
      Enum.find_value(kinds(schema), fn kind ->
        plural = get_in(schema, ["entities", kind, "plural"])
        if match?({:ok, _}, get(url, "#{plural}/#{URI.encode(key)}")), do: plural
      end)

    body = JSON.encode!(%{"relations" => %{@owner => %{"data" => []}}})

    case plural && request(:patch, "#{url}/#{plural}/#{URI.encode(key)}", body) do
      nil -> {:error, "#{key} is not in rela"}
      {:ok, status, _} when status in [200, 204] -> {:ok, key}
      {:ok, status, body} -> {:error, "rela answered #{status}: #{String.slice(body, 0, 200)}"}
      {:error, text} -> {:error, text}
    end
  end

  defp read(url, plurals) do
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

  defp get(url, path) do
    case request(:get, "#{url}/#{path}", nil) do
      {:ok, 200, body} -> {:ok, JSON.decode!(body)}
      {:ok, status, _} -> {:error, "rela at #{url} answered #{status} to #{path}"}
      error -> error
    end
  end

  defp request(method, address, body) do
    headers = [{~c"accept", ~c"application/json"}]
    address = String.to_charlist(address)

    request =
      if body,
        do: {address, headers, ~c"application/json", body},
        else: {address, headers}

    case :httpc.request(method, request, [timeout: 10_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, body}} -> {:ok, status, body}
      other -> {:error, "rela at #{address} did not answer: #{inspect(other)}"}
    end
  end
end
