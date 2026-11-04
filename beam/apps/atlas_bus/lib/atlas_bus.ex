defmodule AtlasBus do
  @moduledoc """
  The Bus: every layer talks only to it.

  It reads a message's envelope (`AtlasBus.Envelope`) and never its content. It routes on
  the envelope's class:

  | Class      | From      | Goes to                                                     |
  |------------|-----------|-------------------------------------------------------------|
  | `fact`     | any layer | the store (State), to be stored                             |
  | `read`     | any layer | the store (State), to be answered                           |
  | `stored`   | the store | its address, the sender of the fact (acknowledgement), and  |
  |            |           | every listener of its kind (hint): one message, both jobs   |
  | `refused`  | the store | its address only                                            |
  | `answer`   | the store | its address only                                            |
  |            | or a layer|                                                             |
  | `fault`    | Control   | its address only (a layer's endpoint): a failure to offer   |
  |            |           | or cause, in the test environment only; a prod Bus refuses  |
  |            |           | it (IS-Atlas-23)                                            |

  A reply carries the id of the message it answers. Delivery is not promised: a sender
  that gets no reply sends the same message again, with the same id.

  A process receives messages as `{:atlas_bus, %AtlasBus.Envelope{}, content}`.
  """

  alias AtlasBus.{Envelope, Router}

  @doc "Make the calling process the endpoint `name`; replies addressed to `name` come here."
  defdelegate attach(name), to: Router

  @doc "Send the calling process every hint (a `stored`) of kind `kind`."
  defdelegate listen(kind), to: Router

  @doc """
  Put a message on the Bus from the calling process, which must be attached.
  Returns an error only for a message the Bus will not route.
  """
  def send(%Envelope{} = envelope, content), do: Router.route(envelope, content)
  def send(_other, _content), do: {:error, :not_an_envelope}

  @doc "The endpoint facts and reads go to."
  def store, do: Application.fetch_env!(:atlas_bus, :store)

  @doc "The environment this Bus serves."
  def environment, do: Application.fetch_env!(:atlas_bus, :environment)

  @doc "Test environment only (prod refuses): drop the next `count` hints, to show reconciling."
  defdelegate drop_hints(count), to: Router

  @doc "The classes of message the Bus routes."
  def classes, do: Router.classes()
end
