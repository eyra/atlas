defmodule AtlasAgent.Client do
  @moduledoc """
  One connection to Control of an environment, speaking its protocol
  (`bff/README.md`) as the TUI does: hello, open a path, submit a form. It waits
  for what it asked and passes over the rest (hints, notices, reconciles).

  Everything it knows comes from Control's pages: a form names the fields it asks and
  where to submit them; a stored fact's page has the fact's path; a refused form says why.
  """

  defstruct [:socket, :env]

  @connect_timeout 2_000
  # A page answers an open at once; a submit waits until State stored or refused it, and
  # Control sends a fact again on its own while State does not answer.
  @page_wait 10_000
  @stored_wait 60_000

  @doc """
  Connect to Control at `settings[\"control\"]` and say hello for `env`, as `as`: an
  `agent`, or a `migration` (which may set what the description marks as set by one).
  """
  def connect(env, settings, as \\ "agent") do
    host = settings["control"]["host"] |> String.to_charlist()
    port = settings["control"]["port"]
    options = [:binary, packet: :line, active: false, buffer: 4_194_304]

    with {:ok, socket} <- tcp_connect(host, port, options, env),
         client = %__MODULE__{socket: socket, env: env},
         :ok <- send_line(client, hello(env, as)),
         {:ok, _welcome} <- await(client, @page_wait, &welcome/1),
         # Control shows its start page after the welcome; it is not what anyone asked.
         {:ok, _home} <- await(client, @page_wait, &page(&1, ["open"])) do
      {:ok, client}
    end
  end

  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)

  # The contract version this client implements; Control sends a too old one away.
  @version AtlasBFFContract.Blocks.__schema__().version

  @doc "The hello this client says: its environment, what it is, and its contract version."
  def hello(env, as), do: %{"op" => "hello", "env" => env, "client" => as, "spec" => @version}

  @doc "The page at `path`."
  def open(client, path) do
    with :ok <- send_line(client, %{"op" => "open", "to" => path}) do
      await(client, @page_wait, &page(&1, ["open"]))
    end
  end

  @doc """
  Submit `values` (text) to what a form's `submit_to` (or a confirm's `confirm_to`) names:
  an endpoint and its params. With why (`cause`) when given. Answers
  `{:stored, page}` with the page Control shows after it was stored, or `{:refused, reasons}`.
  """
  def submit(client, to, values, cause \\ nil) do
    message = %{
      "op" => "submit",
      "endpoint" => to["endpoint"],
      "params" => to["params"] || %{},
      "values" => values
    }

    message = if cause, do: Map.put(message, "cause", cause), else: message

    with :ok <- send_line(client, message),
         {:ok, page} <- await(client, @stored_wait, &page(&1, ["stored", "refused"])) do
      case page["reason"] do
        "stored" ->
          {:stored, page}

        "refused" ->
          errors = page |> blocks("form") |> Enum.flat_map(&(&1["errors"] || []))
          errors = if errors == [], do: page["refused"] || [], else: errors
          {:refused, if(errors == [], do: ["refused"], else: errors)}
      end
    end
  end

  @doc "The props of every block of `type` on `page`."
  def blocks(page, type),
    do: for(%{"type" => ^type, "props" => props} <- page["blocks"] || [], do: props)

  @doc "The last part of a path, which is the key of the fact it shows."
  def key_of(path), do: path |> String.split("/") |> List.last() |> URI.decode()

  defp tcp_connect(host, port, options, env) do
    case :gen_tcp.connect(host, port, options, @connect_timeout) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, _} ->
        {:error,
         "Control #{env} does not answer at #{host}:#{port}. " <>
           "Is it running? See `atlas status --env #{env}`."}
    end
  end

  defp welcome(%{"op" => "welcome"}), do: true
  defp welcome(%{"op" => "bye", "text" => text}), do: {:error, text}
  defp welcome(_message), do: false

  defp page(%{"op" => "page", "reason" => reason}, reasons), do: reason in reasons
  defp page(%{"op" => "bye", "text" => text}, _reasons), do: {:error, text}
  defp page(_message, _reasons), do: false

  # The first message `wanted` says true for; `{:error, text}` from it ends the wait.
  defp await(client, timeout, wanted) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_until(client, deadline, wanted)
  end

  defp await_until(client, deadline, wanted) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    case recv(client, left) do
      {:ok, message} ->
        case wanted.(message) do
          true -> {:ok, message}
          false -> await_until(client, deadline, wanted)
          {:error, _} = error -> error
        end

      {:error, :timeout} ->
        {:error, "Control #{client.env} did not answer in time"}

      {:error, _} ->
        {:error, "Control #{client.env} closed the connection"}
    end
  end

  defp recv(client, timeout) do
    with {:ok, line} <- :gen_tcp.recv(client.socket, 0, timeout) do
      case JSON.decode(line) do
        {:ok, message} -> {:ok, message}
        {:error, _} -> {:ok, %{}}
      end
    end
  end

  defp send_line(client, message) do
    case :gen_tcp.send(client.socket, [JSON.encode!(message), "\n"]) do
      :ok -> :ok
      {:error, _} -> {:error, "Control #{client.env} closed the connection"}
    end
  end
end
