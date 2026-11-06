defmodule AtlasControl.WorkerPages do
  @moduledoc "Worker content uses ordinary BFF blocks; Console owns its renderer and shell."
  alias AtlasControl.{Pages, Workers}
  require AtlasControl.Blocks, as: Blocks

  def target(params) do
    %{
      "worker" => %{
        "environment" => AtlasBus.environment(),
        "machine" => params.machine,
        "worker" => params.worker
      },
      "turn" => params.turn,
      "attempt" => params.attempt
    }
  end

  def render({:worker_page, :workers, _}, description, actor, read, _form) do
    case call("worker_overview", %{}, description, actor, read) do
      {:ok, %{"workers" => workers}} ->
        rows =
          for worker <- workers do
            execution = worker["execution"]
            identity = execution["worker"]

            Blocks.row(
              label: identity["worker"],
              detail: "#{identity["machine"]} · #{execution["turn"]} · #{worker["state"]}",
              to: path(execution)
            )
          end

        page("Workers", "/", [
          Blocks.list(
            title: "Running executions",
            rows: rows,
            empty: "No running execution is recorded."
          )
        ])

      {:error, reason} ->
        error(reason, "/")
    end
  end

  def render({:worker_page, mode, params}, description, actor, read, form) do
    execution = target(params)

    case call("worker_inspect", %{"execution" => execution}, description, actor, read) do
      {:ok, %{"view" => view}} ->
        if mode == :worker_guidance do
          guidance(view, execution, form)
        else
          detail(view, execution, description, actor, read)
        end

      {:error, reason} ->
        error(reason, "/workers")
    end
  end

  defp detail(view, execution, description, actor, read) do
    descriptor = view["descriptor"]

    pairs = [
      {"Environment", execution["worker"]["environment"]},
      {"Machine", execution["worker"]["machine"]},
      {"Worker", execution["worker"]["worker"]},
      {"Turn", execution["turn"]},
      {"Attempt", execution["attempt"]},
      {"Item", view["item"]},
      {"Item title", view["item_title"]},
      {"State", view["state"]},
      {"Harness", descriptor["harness"]},
      {"Harness version", descriptor["harness_version"]},
      {"Configured model", descriptor["configured_model"]},
      {"Reported model", descriptor["reported_model"]},
      {"Activity", view["activity"]},
      {"Activity timestamp", view["activity_at"]},
      {"Lease until", view["lease_until"]},
      {"Confirmed at", view["confirmed_at"]},
      {"Guidance",
       if(view["guidance"]["available"], do: "Available", else: view["guidance"]["reason"])}
    ]

    actions =
      if view["guidance"]["available"],
        do: [
          Blocks.action(
            label: "Queue guidance for this turn",
            key: "g",
            to: path(execution, :worker_guidance)
          )
        ],
        else: []

    actions =
      if view["item_to"],
        do: actions ++ [Blocks.action(label: "Open current item", key: "i", to: view["item_to"])],
        else: actions

    content =
      Blocks.item(
        title: "Worker #{execution["worker"]["worker"]}",
        fields: Enum.map(pairs, fn {k, v} -> Blocks.pair(label: k, value: text(v)) end),
        actions: actions
      )

    history =
      case call("worker_history", %{"execution" => execution}, description, actor, read) do
        {:ok, data} ->
          fields =
            for interaction <- data["interactions"] do
              projection = interaction["projection"]

              status =
                projection["proven"] <> if(projection["uncertain"], do: " (uncertain)", else: "")

              Blocks.pair(
                label: "#{interaction["actor"]} · #{status}",
                value: interaction["body"]
              )
            end

          note =
            if data["more"],
              do: "First history page; full bounded history is available through worker_history.",
              else: "Durable guidance"

          Blocks.item(title: note, fields: fields)

        {:error, reason} ->
          Blocks.item(
            title: "History unavailable",
            fields: [Blocks.pair(label: "Reason", value: reason)]
          )
      end

    page("Worker #{execution["worker"]["worker"]}", "/workers", [
      {"worker", content},
      {"guidance-history", history}
    ])
  end

  defp guidance(view, execution, form) do
    if view["guidance"]["available"] do
      values = form[:values] || %{}
      key = values["client_key"] || form[:worker_client_key]

      inputs = [
        Blocks.input(
          name: "client_key",
          label: "Submission key",
          kind: "readonly",
          value: key,
          required: true
        ),
        Blocks.input(
          name: "body",
          label: "Literal guidance for #{execution["turn"]}",
          kind: "multiline",
          value: values["body"] || "",
          required: true
        ),
        Blocks.input(
          name: "cause",
          label: "Why",
          kind: "text",
          value: values["cause"] || "",
          required: true
        )
      ]

      params =
        Map.merge(execution["worker"], Map.take(execution, ~w(turn attempt)))
        |> Map.delete("environment")

      block =
        Blocks.form(
          title: "Queue guidance — not a machine control",
          inputs: inputs,
          submit_label: "Queue for this exact turn",
          submit_to: Blocks.call(endpoint: "queue_worker_guidance", params: params),
          cancel_to: path(execution),
          errors: form[:errors] || []
        )

      page("Guidance", path(execution), [block])
    else
      error(view["guidance"]["reason"], path(execution))
    end
  end

  def path(execution, mode \\ :worker) do
    params = %{
      machine: execution["worker"]["machine"],
      worker: execution["worker"]["worker"],
      turn: execution["turn"],
      attempt: execution["attempt"]
    }

    Pages.path({:worker_page, mode, params})
  end

  defp call(op, request, description, actor, read),
    do:
      Workers.handle(op, request, description, actor, read, fn _, _ ->
        raise "rendering cannot write"
      end)

  def error(reason, back),
    do:
      page("Worker unavailable", back, [
        Blocks.item(
          title: "Worker unavailable",
          fields: [Blocks.pair(label: "Reason", value: reason)]
        )
      ])

  defp text(nil), do: "Unknown"
  defp text(""), do: "—"
  defp text(value), do: to_string(value)

  defp page(title, back, blocks) do
    content =
      Enum.with_index(blocks, fn block, index ->
        case block do
          {id, value} -> {id, value}
          value -> {"worker-#{index}", value}
        end
      end)

    Map.merge(%{title: title, back: back}, Blocks.view_model(content, []))
  end
end
