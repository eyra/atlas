defmodule AtlasControl.Shell do
  @moduledoc "Native shell metadata from the selected description, separate from page content."

  alias AtlasControl.Pages
  require AtlasControl.Blocks, as: Blocks

  @doc "Build a fresh shell; the optional target selects content without opening a page."
  def boot(description, by_kind, target \\ nil) do
    with {:ok, title, configured} <- configuration(description),
         true <- is_nil(target) or text?(target, 2_048),
         true <- Enum.all?(configured, &valid_tab?(&1, description)),
         true <- distinct?(configured, "id") and distinct?(configured, "to") do
      tabs =
        configured
        |> Enum.filter(fn tab ->
          tab["assigned"] != true or Pages.assigned_start?(description, by_kind)
        end)
        |> Enum.map(fn tab ->
          Blocks.shell_tab(id: tab["id"], label: tab["label"], to: tab["to"])
        end)

      if tabs == [] do
        {:error, "Shell has no eligible configured tabs"}
      else
        initial = initial_target(target, description, tabs)
        active = Enum.find(tabs, &within?(initial, &1["to"]))
        env = AtlasBus.environment()
        spec = Blocks.version()

        # Navigation and request target do not change the revision. Configuration,
        # actor-visible tab set, environment and contract version do.
        revision =
          [title, env, spec, Enum.map(tabs, &[&1["id"], &1["label"], &1["to"]])]
          |> JSON.encode!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        {:ok,
         Blocks.shell(
           title: title,
           env: env,
           spec: spec,
           revision: revision,
           tabs: tabs,
           initial_to: initial,
           active_tab: active && active["id"]
         )}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Invalid shell configuration or target"}
    end
  end

  defp configuration(description) do
    case description["shell"] do
      %{"title" => title, "tabs" => tabs}
      when is_list(tabs) and length(tabs) <= 64 ->
        if text?(title, 128) and Map.keys(description["shell"]) -- ["title", "tabs"] == [],
          do: {:ok, title, tabs},
          else: {:error, "Invalid shell configuration"}

      _ ->
        {:error, "No shell navigation is configured"}
    end
  end

  defp valid_tab?(%{"id" => id, "label" => label, "to" => to} = tab, description) do
    text?(id, 64) and text?(label, 128) and text?(to, 2_048) and
      Map.keys(tab) -- ["id", "label", "to", "assigned"] == [] and
      Map.get(tab, "assigned", false) in [true, false] and
      case Pages.route(if(is_binary(to), do: to, else: "")) do
        :home -> tab["assigned"] == true and Pages.assigned_rule(description) != nil
        {:list, kind} -> Map.has_key?(description["entities"] || %{}, kind)
        _ -> false
      end
  end

  defp valid_tab?(_, _description), do: false

  defp initial_target(target, description, tabs) do
    route = if is_binary(target), do: target |> Pages.route() |> Pages.resolve(description)

    canonical =
      case route do
        :home ->
          "/"

        :kinds ->
          "/_kinds"

        {page, kind} when page in [:list, :new] ->
          if known_kind?(kind, description), do: Pages.path(route)

        {page, kind, _key} when page in [:item, :edit, :delete, :new] ->
          if known_kind?(kind, description), do: Pages.path(route)

        {page, kind, _key, _relation} when page in [:links, :set, :remove] ->
          if known_kind?(kind, description), do: Pages.path(route)

        _ ->
          nil
      end

    # A removed overview (including an actor-ineligible root) falls back to the
    # first configured tab. Valid detail/form deep links remain ordinary open targets.
    index? = route == :home or match?({:list, _}, route)
    configured? = Enum.any?(tabs, &(&1["to"] == canonical))

    if canonical && (not index? or configured?), do: canonical, else: hd(tabs)["to"]
  end

  defp known_kind?(kind, description),
    do: Map.has_key?(description["entities"] || %{}, kind)

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) <= max and String.trim(value) != ""

  defp distinct?(tabs, field) do
    values = Enum.map(tabs, & &1[field])
    Enum.uniq(values) == values
  end

  defp within?(target, to),
    do: target == to or (to != "/" and String.starts_with?(target, to <> "/"))
end
