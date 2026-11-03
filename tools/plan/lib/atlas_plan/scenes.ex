defmodule AtlasPlan.Scenes do
  @moduledoc """
  Reads SCENES.md: its scenes, their use cases and the issues of those, with their codes
  as the file writes them, normalised to the full code (`IS-01` is `IS-Atlas-01`).

  - A scene is a `## SC-Atlas-NN: Title` section. Its description is the section without
    its tables of use cases and issues, its `###` headings as `##`.
  - A use case is a row of a scene's `| Code | Use case | ... |` table (the third column
    is what Melle can test), or, in a draft scene, `UC-Atlas-NN Title (more)` in prose.
  - An issue is a row of a scene's `| Code | Use case | Issue |` table. Its title is the
    start of its text; its parent the first use case named (`all`: the scene's first).

  Every item is `%{kind, code, number, title, description, parent, also}`; `also` names
  further use cases an issue is for, which a fact cannot point at (one parent at most).
  """

  @code ~r/\b(SC|UC|IS)-(?:Atlas-)?(\d{2})\b/

  def parse(text) do
    scenes = text |> String.split(~r/^## (?=SC-Atlas-\d+:)/m) |> tl() |> Enum.map(&scene/1)

    scene_items = Enum.map(scenes, & &1.item)
    use_cases = Enum.flat_map(scenes, & &1.use_cases)
    issues = Enum.flat_map(scenes, & &1.issues)

    %{
      scenes: Enum.sort_by(scene_items, & &1.number),
      use_cases: Enum.sort_by(use_cases, & &1.number),
      issues: Enum.sort_by(issues, & &1.number)
    }
  end

  @doc "The full code of a short one: `IS-01` → `IS-Atlas-01`."
  def full(code) do
    case Regex.run(@code, code) do
      [_, prefix, number] -> "#{prefix}-Atlas-#{number}"
      nil -> code
    end
  end

  @doc "Every code in `text`, short or full, replaced by `fun.(full code)`."
  def rewrite(text, fun),
    do: Regex.replace(@code, text, fn _, prefix, number -> fun.("#{prefix}-Atlas-#{number}") end)

  defp scene(section) do
    [heading | lines] = String.split(section, "\n")
    [_, number, title] = Regex.run(~r/^SC-Atlas-(\d+): (.+)$/, String.trim(heading))
    code = "SC-Atlas-#{number}"
    {preamble, parts} = subsections(lines)

    use_cases = Enum.flat_map(parts, &use_cases(&1, code))
    first_use_case = use_cases |> Enum.sort_by(& &1.number) |> List.first()
    issues = Enum.flat_map(parts, &issues(&1, code, first_use_case))

    kept = Enum.reject(parts, fn {_heading, body} -> table?(body) end)

    description =
      [Enum.join(preamble, "\n") | Enum.map(kept, fn {h, body} -> "## #{h}\n" <> body end)]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{
      item: item("scene", code, title, description, nil),
      use_cases: use_cases,
      issues: issues
    }
  end

  defp item(kind, code, title, description, parent, also \\ []) do
    [_, number] = Regex.run(~r/(\d+)$/, code)

    %{
      kind: kind,
      code: code,
      number: String.to_integer(number),
      title: String.trim(title),
      description: String.trim(description),
      parent: parent,
      also: also
    }
  end

  # `### Heading` parts of a scene: {lines before the first, [{heading, body}]}.
  defp subsections(lines) do
    {preamble, rest} = Enum.split_while(lines, &(not String.starts_with?(&1, "### ")))

    parts =
      rest
      |> Enum.chunk_while(
        nil,
        fn
          "### " <> heading, nil -> {:cont, {heading, []}}
          "### " <> heading, {h, body} -> {:cont, {h, Enum.reverse(body)}, {heading, []}}
          line, {h, body} -> {:cont, {h, [line | body]}}
        end,
        fn
          nil -> {:cont, nil}
          {h, body} -> {:cont, {h, Enum.reverse(body)}, nil}
        end
      )
      |> Enum.map(fn {h, body} -> {String.trim(h), Enum.join(body, "\n")} end)

    {preamble, parts}
  end

  defp table?(body), do: body =~ ~r/^\| Code \|/m

  defp rows(body) do
    for line <- String.split(body, "\n"),
        String.starts_with?(line, "| "),
        not String.starts_with?(line, "| Code"),
        not String.starts_with?(line, "|---"),
        do: line |> String.trim() |> String.trim_leading("| ") |> String.trim_trailing(" |")
  end

  # Use cases: a table, or prose in a draft scene.
  defp use_cases({heading, body}, scene) do
    cond do
      not String.starts_with?(heading, "Use cases") -> []
      table?(body) -> Enum.map(rows(body), &use_case_row(&1, scene, third_column(body)))
      true -> prose_use_cases(body, scene)
    end
  end

  # The heading of a table's third column ("Melle can test in the TUI").
  defp third_column(body) do
    case Regex.run(~r/^\| Code \| [^|]+ \| ([^|]+) \|/m, body) do
      [_, heading] -> String.trim(heading)
      nil -> "More"
    end
  end

  defp use_case_row(row, scene, heading) do
    [code, title, text] = String.split(row, " | ", parts: 3)
    item("use_case", full(code), title, "#{heading}:\n#{text}", scene)
  end

  # "UC-Atlas-16 Expose Control's actions as tools (more). UC-Atlas-17 ...": each runs to
  # the next code; its title to the first "(" or "."; the rest is its description. The
  # last one ends with its first sentence; what follows belongs to the scene.
  defp prose_use_cases(body, scene) do
    # A code inside parentheses is a reference, not a use case of its own.
    starts =
      ~r/UC-Atlas-(\d+) /
      |> Regex.scan(body, return: :index)
      |> Enum.filter(fn [{at, _}, _] -> depth(binary_part(body, 0, at)) == 0 end)

    starts
    |> Enum.with_index()
    |> Enum.map(fn {[{at, length}, _], i} ->
      from = at + length

      segment =
        case Enum.at(starts, i + 1) do
          [{next, _}, _] -> binary_part(body, from, next - from)
          nil -> body |> binary_part(from, byte_size(body) - from) |> first_sentence()
        end

      code = body |> binary_part(at, length) |> String.trim()
      segment = segment |> String.trim() |> String.trim_trailing(",")
      {title, rest} = split_title(segment)
      item("use_case", code, title, rest, scene)
    end)
  end

  defp depth(text) do
    text
    |> String.graphemes()
    |> Enum.reduce(0, fn
      "(", d -> d + 1
      ")", d -> max(d - 1, 0)
      _, d -> d
    end)
  end

  defp split_title(segment) do
    # Groups left unmatched at the end are left out of the result.
    case Regex.run(~r/^(.+?)(?: \((.*?)\)[.,]?|\.)(?:\s+(.*))?$/s, segment) do
      [_, title] ->
        {title, ""}

      [_, title, paren] ->
        {title, sentence(paren)}

      [_, title, paren, rest] ->
        {title, Enum.join(Enum.reject([sentence(paren), rest], &(&1 == "")), " ")}

      nil ->
        {segment, ""}
    end
  end

  defp sentence(""), do: ""

  defp sentence(text),
    do: String.capitalize(String.first(text)) <> String.slice(text, 1..-1//1) <> "."

  defp first_sentence(text) do
    case String.split(text, ~r/(?<=\.)\s/, parts: 2) do
      [first | _] -> first
    end
  end

  # Issues: `| IS-NN | UC-NN, MM | text |`.
  defp issues({heading, body}, scene, first_use_case) do
    if String.starts_with?(heading, "Issues") and table?(body),
      do: Enum.map(rows(body), &issue_row(&1, scene, first_use_case)),
      else: []
  end

  defp issue_row(row, scene, first_use_case) do
    [code, use_cases, text] = String.split(row, " | ", parts: 3)

    {parent, also, note} =
      case Regex.scan(~r/\d{2}/, use_cases) |> List.flatten() do
        [] ->
          {first_use_case && first_use_case.code, [], "For all use cases of #{scene}."}

        [first | more] ->
          also = Enum.map(more, &"UC-Atlas-#{&1}")
          note = if also == [], do: nil, else: "Also for #{Enum.join(also, ", ")}."
          {"UC-Atlas-#{first}", also, note}
      end

    description = Enum.join(Enum.reject([text, note], &is_nil/1), "\n\n")
    item("issue", full(code), title(text), description, parent, also)
  end

  @doc """
  An issue's title from its text: the first sentence, up to its first " (" or "; ", and
  when still long, up to its last ", " within 90 characters.
  """
  def title(text) do
    title =
      text
      |> first_sentence()
      |> String.trim_trailing(".")
      |> String.split(~r/ \(|; /, parts: 2)
      |> hd()

    cond do
      String.length(title) <= 90 ->
        title

      true ->
        head = String.slice(title, 0, 90)

        case :binary.matches(head, ", ") do
          [] -> String.replace(head, ~r/\s+\S*$/, "") <> "…"
          matches -> binary_part(head, 0, matches |> List.last() |> elem(0))
        end
    end
  end
end
