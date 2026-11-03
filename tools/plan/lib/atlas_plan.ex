defmodule AtlasPlan do
  @moduledoc """
  UC-Atlas-05: loads the plan in SCENES.md into Atlas through Control, with the agent
  client, as an agent would: every scene, use case and issue, in code order (parents
  first), then the pull requests of the issues and their stages from a links file.

  Atlas may already hold items, Melle's own among them, so:

  - An existing item is never changed. An item of the file that is already there (same
    kind, same title, under the same parent) is skipped and mapped to it; that is what
    makes a second run create nothing.
  - Every other item is created with the next code Control makes. When that is not the
    file's code (it is taken), the mapping says so: `SC-Atlas-01 → SC-Atlas-02`. Parents
    and every code mentioned in a title or description follow the mapping.
  - A dry run reads, works out the mapping and prints what it would do, and writes
    nothing. The real run stops when Control makes another code than the one worked
    out (someone created an item meanwhile); running it again goes on from there.

  The links file: `{"pull_requests": [{"url": ..., "issue": "IS-01"}],
  "stages": {"IS-02": "testing"}}`. A stage is set on an issue created in the same run;
  linking a pull request again from the same issue changes nothing.
  """

  alias AtlasPlan.Scenes

  @kinds [scenes: "scene", use_cases: "use_case", issues: "issue"]
  @default_stage "specification"

  @doc "Load `scenes` (SCENES.md's text) with `links` (decoded) through `client`."
  def run(client, scenes, links, opts \\ []) do
    plan = Scenes.parse(scenes)
    dry? = Keyword.get(opts, :dry_run, false)
    say = Keyword.get(opts, :say, &IO.puts/1)

    with {:ok, existing} <- existing(client) do
      {steps, mapping} = steps(plan, existing)
      steps = Enum.map(steps, &final(&1, mapping))
      prs = prs(links, mapping)
      stages = links["stages"] || %{}

      say.(summary(plan, steps, prs))
      Enum.each(steps, &say.(line(&1, stages)))
      Enum.each(prs, fn {url, key} -> say.("link    #{key}  #{url}") end)
      say.(mapping_text(mapping))

      if dry?,
        do: {:ok, %{dry_run: true, mapping: mapping, steps: steps}},
        else: write(client, steps, prs, stages, mapping, say)
    end
  end

  # What is there: per kind every key (for the next number), and per parent what hangs
  # under it (to find an item of the file that is already there).
  defp existing(client) do
    with {:ok, scenes} <- AtlasAgent.list(client, "scene"),
         {:ok, use_cases} <- AtlasAgent.list(client, "use_case"),
         {:ok, issues} <- AtlasAgent.list(client, "issue"),
         {:ok, under} <- under(client, scenes ++ use_cases) do
      {:ok,
       %{
         keys: %{"scene" => keys(scenes), "use_case" => keys(use_cases), "issue" => keys(issues)},
         top: scenes,
         under: under
       }}
    end
  end

  defp keys(rows), do: Enum.map(rows, & &1["key"])

  defp under(client, parents) do
    Enum.reduce_while(parents, {:ok, %{}}, fn parent, {:ok, acc} ->
      case AtlasAgent.get(client, parent["key"]) do
        {:ok, item} ->
          rows = Enum.flat_map(item["lists"], & &1["rows"])
          {:cont, {:ok, Map.put(acc, parent["key"], rows)}}

        error ->
          {:halt, error}
      end
    end)
  end

  # Every item of the file: exists (mapped to the key it has) or create (with the key
  # Control will make), in the order they are created.
  defp steps(plan, existing) do
    {steps, {mapping, _taken}} =
      @kinds
      |> Enum.flat_map(fn {group, _kind} -> plan[group] end)
      |> Enum.map_reduce({%{}, existing.keys}, fn item, {mapping, taken} ->
        parent = item.parent && Map.get(mapping, item.parent, item.parent)

        candidates =
          if item.kind == "scene",
            do: existing.top,
            else: Map.get(existing.under, parent, [])

        titles = [item.title, Scenes.rewrite(item.title, &Map.get(mapping, &1, &1))]

        match =
          Enum.find(candidates, fn row ->
            String.starts_with?(row["path"], "/k/#{item.kind}/") and row["label"] in titles
          end)

        case match do
          %{"key" => key} ->
            step = %{item: item, action: :exists, key: key, parent: parent}
            {step, {Map.put(mapping, item.code, key), taken}}

          nil ->
            key = next_key(item.code, taken[item.kind])
            taken = Map.update!(taken, item.kind, &[key | &1])
            step = %{item: item, action: :create, key: key, parent: parent}
            {step, {Map.put(mapping, item.code, key), taken}}
        end
      end)

    {steps, mapping}
  end

  # As Control makes it: the prefix, then one more than the highest number of that prefix.
  defp next_key(code, keys) do
    [_, prefix] = Regex.run(~r/^(.*?)\d+$/, code)
    {:ok, pattern} = Regex.compile("^" <> Regex.escape(prefix) <> "(\\d+)$")

    highest =
      keys
      |> Enum.flat_map(fn key ->
        case Regex.run(pattern, key) do
          [_, n] -> [String.to_integer(n)]
          nil -> []
        end
      end)
      |> Enum.max(fn -> 0 end)

    prefix <> String.pad_leading(Integer.to_string(highest + 1), 2, "0")
  end

  # Titles and descriptions with every code as it is (or will be) in Atlas.
  defp final(step, mapping) do
    rewrite = &Scenes.rewrite(&1, fn code -> Map.get(mapping, code, code) end)

    %{
      step
      | item: %{
          step.item
          | title: rewrite.(step.item.title),
            description: rewrite.(step.item.description)
        }
    }
  end

  defp prs(links, mapping) do
    for %{"url" => url, "issue" => code} <- links["pull_requests"] || [] do
      code = Scenes.full(code)
      {url, Map.get(mapping, code, code)}
    end
  end

  # Writing

  defp write(client, steps, prs, stages, mapping, say) do
    result =
      Enum.reduce_while(steps, {:ok, %{created: 0, existing: 0, stages: 0}}, fn
        %{action: :exists}, {:ok, counts} ->
          {:cont, {:ok, %{counts | existing: counts.existing + 1}}}

        %{action: :create} = step, {:ok, counts} ->
          case create(client, step, stages) do
            {:ok, staged} ->
              say.("created #{step.key}  #{step.item.title}")

              {:cont,
               {:ok, %{counts | created: counts.created + 1, stages: counts.stages + staged}}}

            {:error, text} ->
              {:halt, {:error, text}}
          end
      end)

    with {:ok, counts} <- result do
      linked =
        Enum.count(prs, fn {url, key} ->
          case AtlasAgent.put(client, "pull_request", %{"url" => url}, key) do
            {:ok, pr} ->
              say.("linked  #{pr} to #{key}")
              true

            {:refused, reasons} ->
              say.("not linked #{url} to #{key}: #{Enum.join(reasons, "; ")}")
              false

            {:error, text} ->
              say.("not linked #{url} to #{key}: #{text}")
              false
          end
        end)

      counts = Map.put(counts, :linked, linked)

      say.(
        "Done: #{counts.created} created, #{counts.existing} already there, " <>
          "#{counts.stages} stages set, #{linked} of #{length(prs)} pull requests linked."
      )

      {:ok, Map.merge(counts, %{mapping: mapping})}
    end
  end

  defp create(client, %{item: item} = step, stages) do
    values = %{"title" => item.title, "description" => item.description}

    case AtlasAgent.put(client, item.kind, values, step.parent) do
      {:ok, key} when key == step.key ->
        stage(client, key, stages[short(item.code)] || stages[item.code])

      {:ok, key} ->
        {:error,
         "#{item.code} was stored as #{key}, not #{step.key}: something was created " <>
           "meanwhile. Run again; it goes on from here."}

      {:refused, reasons} ->
        {:error, "#{item.code} refused: #{Enum.join(reasons, "; ")}"}

      {:error, text} ->
        {:error, "#{item.code}: #{text}"}
    end
  end

  defp stage(_client, _key, stage) when stage in [nil, @default_stage], do: {:ok, 0}

  defp stage(client, key, stage) do
    case AtlasAgent.set(client, key, %{"stage" => stage}) do
      {:ok, _} ->
        {:ok, 1}

      {:refused, reasons} ->
        {:error, "#{key} stage #{stage} refused: #{Enum.join(reasons, "; ")}"}

      {:error, text} ->
        {:error, "#{key} stage: #{text}"}
    end
  end

  # IS-Atlas-02 → IS-02, as the links file may write it.
  defp short(code), do: String.replace(code, "-Atlas-", "-")

  # Text

  defp summary(plan, steps, prs) do
    create = Enum.count(steps, &(&1.action == :create))
    exists = length(steps) - create

    "SCENES.md: #{length(plan.scenes)} scenes, #{length(plan.use_cases)} use cases, " <>
      "#{length(plan.issues)} issues; #{length(prs)} pull requests to link. " <>
      "To create: #{create}; already there: #{exists}."
  end

  defp line(step, stages) do
    code =
      if step.key == step.item.code, do: step.key, else: "#{step.key} (file: #{step.item.code})"

    under = if step.parent, do: " in #{step.parent}", else: ""
    stage = stages[short(step.item.code)] || stages[step.item.code]

    stage =
      if step.action == :create and stage not in [nil, @default_stage],
        do: ", stage #{stage}",
        else: ""

    action = if step.action == :create, do: "create ", else: "exists "
    "#{action} #{code}#{under}#{stage}  #{step.item.title}"
  end

  defp mapping_text(mapping) do
    moved = for {code, key} <- Enum.sort(mapping), code != key, do: "  #{code} → #{key}"

    if moved == [],
      do: "Mapping: every code is the file's own.",
      else: Enum.join(["Mapping (SCENES.md → Atlas), where they differ:" | moved], "\n")
  end
end
