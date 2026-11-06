defmodule AtlasBFFContract.Runtime do
  @moduledoc """
  First shared Runtime control vocabulary. Data contracts only: services bind identity,
  permissions, capability truth, correlation, deadlines and lifecycle behavior.

  A viewer attachment does not start or stop a worker. Conversation and harness output
  are not control messages. Guidance/evidence remain the existing adapter contracts.
  """
  use AtlasBFF.Schema

  @wire_version "0.1.0"
  version @wire_version

  defmodel :runtime_worker do
    field :environment, :string, required: true
    field :machine, :string, required: true
    field :worker, :string, required: true
  end

  defmodel :runtime_execution do
    field :worker, :runtime_worker, required: true
    field :turn, :string, required: true
    # Existing unfenced turns omit this; adapters must never invent an attempt.
    field :attempt, :string
  end

  defmodel :runtime_controls do
    field :status, :boolean, required: true
    field :start, :boolean, required: true
    field :stop, :boolean, required: true
    field :stub_mode, :boolean, required: true
  end

  defmodel :runtime_harness_capabilities do
    # Same proven capability slots as execution registration; not a second pipeline.
    field :harness, :string, required: true
    field :harness_version, :string, required: true
    field :capability_version, :string, required: true
    field :configured_model, :string
    field :reported_model, :string
    field :queued_input, :boolean, required: true
    field :durable_accept_query, :boolean, required: true
    field :consumption_evidence, :boolean, required: true
    field :literal_text, :boolean, required: true
  end

  defmodel :runtime_capabilities do
    field :controls, :runtime_controls, required: true
    # Absent means no registered/proven harness capability, not implied support.
    field :harness, :runtime_harness_capabilities
  end

  defmodel :runtime_turn do
    field :execution, :runtime_execution, required: true
    field :item, :string, required: true
    field :state, :string, required: true
    field :activity, :string
    field :lease_until, :string
    field :outcome, :string
    field :reason, :string
  end

  defmodel :runtime_status do
    field :target, :runtime_worker, required: true
    field :engine_running, :boolean, required: true
    field :capabilities, :runtime_capabilities, required: true
    field :item, :string
    field :owner, :string
    field :expected, :string
    field :handover, :string
    field :mode, :string
    field :cannot_run, :string
    field :turns, {:list, :runtime_turn}, required: true
  end

  defmodel :runtime_error do
    field :code, :string, required: true
    field :message, :string, required: true
    field :retryable, :boolean, required: true
  end

  @result %{
    name: :result,
    select: %{"op" => "result", "channel" => "control", "version" => @wire_version},
    required: %{"id" => :string, "target" => :runtime_worker, "status" => :runtime_status},
    effect: :complete
  }
  @error %{
    name: :error,
    select: %{"op" => "error", "channel" => "control", "version" => @wire_version},
    required: %{"id" => :string, "error" => :runtime_error},
    optional: %{"target" => :runtime_worker},
    effect: :error
  }

  @commands [
    {:runtime_status, "status", ["status"], %{}},
    {:runtime_start, "start", ["start"], %{}},
    {:runtime_stop, "stop", ["stop"], %{}},
    {:runtime_attach, "attach", ["attach"], %{}},
    {:runtime_detach, "detach", ["detach"], %{}},
    {:runtime_active, "stub_mode", ["mode", "active"], %{"mode" => "active"}},
    {:runtime_idle, "stub_mode", ["mode", "idle"], %{"mode" => "idle"}},
    {:runtime_silent, "stub_mode", ["mode", "silent"], %{"mode" => "silent"}},
    {:runtime_crash_once, "stub_mode", ["mode", "crash-once"], %{"mode" => "crash once"}},
    {:runtime_crash, "stub_mode", ["mode", "crash"], %{"mode" => "crash"}}
  ]

  protocol(
    for {name, op, words, literals} <- @commands do
      %{
        name: name,
        channel: :runtime,
        direction: :request,
        cli: words,
        request: %{
          select:
            Map.merge(%{"op" => op, "channel" => "control", "version" => @wire_version}, literals),
          required: %{"id" => :string, "target" => :runtime_worker}
        },
        replies: [@result, @error]
      }
    end ++
      [
        %{
          name: :runtime_status_event,
          channel: :runtime,
          direction: :push,
          replies: [
            %{
              name: :status,
              select: %{"op" => "status", "channel" => "event", "version" => @wire_version},
              required: %{
                "sequence" => :integer,
                "target" => :runtime_worker,
                "status" => :runtime_status
              },
              effect: :progress
            }
          ]
        }
      ]
  )
end

defmodule AtlasBFFContract.Runtime.Protocol do
  @moduledoc "Generated typed Runtime codecs, dispatch and literal CLI command plumbing."
  use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Runtime, channel: :runtime
end

defmodule AtlasBFFContract.Runtime.Types do
  @moduledoc "Generated shared data structures for any Atlas client or service adapter."
  use AtlasBFF.Targets.Client, contract: AtlasBFFContract.Runtime
end
