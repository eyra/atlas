defmodule AtlasBFFContract.Workers do
  @moduledoc "Worker reads and durable guidance; shared execution identities, no lifecycle controls."
  use AtlasBFF.Schema
  version "0.1.0"
  models_from(AtlasBFFContract.Runtime)

  defmodel :worker_descriptor do
    field :harness, :string, required: true
    field :harness_version, :string, required: true
    field :configured_model, :string, required: true
    field :reported_model, :string
    field :capability_version, :string, required: true
    field :queued_input, :boolean, required: true
    field :durable_accept_query, :boolean, required: true
    field :consumption_evidence, :boolean, required: true
  end

  defmodel :worker_guidance_availability do
    field :available, :boolean, required: true
    field :reason, :string
  end

  defmodel :worker_view do
    field :execution, :runtime_execution, required: true
    field :descriptor, :worker_descriptor, required: true
    field :item, :string
    field :item_title, :string
    field :item_to, :string
    field :state, :string, required: true
    field :activity, :string
    field :activity_at, :string
    field :lease_until, :string
    field :outcome, :string
    field :confirmed_at, :string, required: true
    field :guidance, :worker_guidance_availability, required: true
  end

  defmodel :worker_guidance_input do
    field :client_key, :string, required: true
    field :body, :string, required: true
    field :cause, :string, required: true
  end

  defmodel :worker_receipt_projection do
    field :proven, :string, required: true
    field :uncertain, :boolean, required: true
    field :closures, {:list, :string}, required: true
  end

  defmodel :worker_interaction do
    field :key, :string, required: true
    field :environment, :string, required: true
    field :actor, :string, required: true
    field :client_key, :string, required: true
    field :body, :string, required: true
    field :body_digest, :string, required: true
    field :worker, :string, required: true
    field :turn, :string, required: true
    field :attempt, :string, required: true
    field :mode, :string, required: true
    field :execution, :string, required: true
    field :cause, :string, required: true
    field :recorded_at, :string, required: true
    field :recorded_position, :integer, required: true
    field :projection, :worker_receipt_projection, required: true
    field :receipt_count, :integer, required: true
  end

  defmodel :worker_receipt do
    field :key, :string, required: true
    field :environment, :string, required: true
    field :interaction, :string, required: true
    field :worker, :string, required: true
    field :turn, :string, required: true
    field :attempt, :string, required: true
    field :execution, :string, required: true
    field :stage, :string, required: true
    field :evidence_id, :string, required: true
    field :cause, :string, required: true
    field :writer, :string, required: true
    field :recorded_at, :string, required: true
    field :recorded_position, :integer, required: true
    field :admission_id, :string
    field :consumption_id, :string
    field :reason, :string
  end

  @operations [
    {:worker_overview, %{}, %{}, %{"workers" => {:list, :worker_view}, "confirmed_at" => :string},
     %{}},
    {:worker_inspect, %{"execution" => :runtime_execution}, %{}, %{"view" => :worker_view}, %{}},
    {:worker_submit, %{"execution" => :runtime_execution, "guidance" => :worker_guidance_input},
     %{}, %{"interaction" => :worker_interaction}, %{}},
    {:worker_query, %{"execution" => :runtime_execution, "client_key" => :string}, %{},
     %{"found" => :boolean}, %{"interaction" => :worker_interaction}},
    {:worker_history, %{"execution" => :runtime_execution}, %{"cursor" => :string},
     %{"interactions" => {:list, :worker_interaction}, "cursor" => :string, "more" => :boolean},
     %{}},
    {:worker_receipts, %{"execution" => :runtime_execution, "interaction" => :string},
     %{"cursor" => :string},
     %{"receipts" => {:list, :worker_receipt}, "cursor" => :string, "more" => :boolean}, %{}}
  ]

  protocol(
    for {name, required, optional, result, result_optional} <- @operations do
      %{
        name: name,
        channel: :control,
        direction: :request,
        request: %{
          select: %{"op" => Atom.to_string(name), "channel" => "control", "version" => "0.1.0"},
          required: Map.put(required, "id", :string),
          optional: optional
        },
        replies: [
          %{
            name: :result,
            effect: :complete,
            select: %{
              "op" => Atom.to_string(name) <> "_result",
              "channel" => "control",
              "version" => "0.1.0"
            },
            required: Map.put(result, "id", :string),
            optional: result_optional
          },
          %{
            name: :error,
            effect: :error,
            select: %{
              "op" => Atom.to_string(name) <> "_error",
              "channel" => "control",
              "version" => "0.1.0"
            },
            required: %{"id" => :string, "error" => :runtime_error}
          }
        ]
      }
    end
  )
end

defmodule AtlasBFFContract.Workers.Protocol do
  use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Workers, channel: :control
end
