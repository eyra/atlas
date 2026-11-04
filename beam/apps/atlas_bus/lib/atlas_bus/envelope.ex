defmodule AtlasBus.Envelope do
  @moduledoc """
  The only part of a message the Bus reads (architecture v3, section 5).

  - `id`: chosen by the sender; the same on every resend. A reply carries the id of the
    message it answers, so "stored #42" answers "fact #42".
  - `environment`: `test` or `prod`. The Bus refuses a message of the other environment.
  - `class`: `fact`, `stored`, `refused`, `read`, `answer` or `fault` (see `AtlasBus`).
  - `kind`: the name of a kind of fact as rela's description defines it. The Bus routes
    hints on the exact name and never knows what it means.
  - `address`: the endpoint a reply goes to (the sender of the fact or read).
    Facts and reads always go to the store.
  - `sender`: the endpoint that sent it. The Bus fills it in from the sending
    process's endpoint, so no sender can pose as another.
  - `position`: on `stored` only, the fact's place in the environment's order.
  """

  @enforce_keys [:id, :environment, :class, :kind]
  defstruct [:id, :environment, :class, :kind, :address, :sender, :position]

  @type t :: %__MODULE__{
          id: String.t(),
          environment: String.t(),
          class: String.t(),
          kind: String.t(),
          address: String.t() | nil,
          sender: String.t() | nil,
          position: non_neg_integer() | nil
        }

  @doc "A fact or a read, with a fresh id, in the Bus's environment."
  def new(class, kind, opts \\ []) do
    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, &new_id/0),
      environment: Keyword.get_lazy(opts, :environment, &AtlasBus.environment/0),
      class: class,
      kind: kind
    }
  end

  @doc "A reply to `envelope`: same id and kind, addressed to its sender."
  def reply(%__MODULE__{} = envelope, class, opts \\ []) do
    %__MODULE__{
      id: envelope.id,
      environment: envelope.environment,
      class: class,
      kind: envelope.kind,
      address: envelope.sender,
      position: Keyword.get(opts, :position)
    }
  end

  @doc "A sortable, unique id: milliseconds since the epoch, then random bytes."
  def new_id do
    stamp = System.system_time(:millisecond) |> Integer.to_string(36) |> String.downcase()
    random = :crypto.strong_rand_bytes(6) |> Base.encode32(case: :lower, padding: false)
    stamp <> "-" <> random
  end

  @doc false
  def validate(%__MODULE__{} = envelope) do
    case Enum.reject([:id, :environment, :class, :kind], &filled?(Map.fetch!(envelope, &1))) do
      [] -> :ok
      missing -> {:error, {:incomplete_envelope, missing}}
    end
  end

  def validate(_other), do: {:error, :not_an_envelope}

  defp filled?(value), do: is_binary(value) and value != ""
end
