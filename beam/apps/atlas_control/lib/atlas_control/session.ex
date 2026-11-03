defmodule AtlasControl.Session do
  @moduledoc """
  One connected client. Speaks Control's protocol (`spec/README.md`) as JSON
  lines over TCP, and reaches State only over the Bus, as its own endpoint.

  - Opening a path reads what the page needs from State and sends the page.
  - A submit becomes a fact. The client is told it waits; the change shows only once
    State has stored it. A fact without an answer is sent again with the same id, after
    5 seconds, then twice as long each time, up to a minute.
  - A hint (a `stored` of a kind on screen) re-reads and sends the page again. A form is
    never redrawn under the user's hands; they get a notice instead.
  - The client asks for a refresh on an interval (it reconciles); a lost hint only delays.
  """
  use GenServer, restart: :temporary

  require Logger

  alias AtlasBus.Envelope
  alias AtlasControl.Pages

  @description "_description"
  @read_timeout 2_000
  @read_attempts 3
  @first_resend 5_000
  @last_resend 60_000
  # How often a create tries the next number when its key turns out to be taken.
  @key_tries 10

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @impl true
  def init(socket) do
    endpoint = "control/session-#{System.unique_integer([:positive])}"
    :ok = AtlasBus.attach(endpoint)

    {:ok,
     %{
       socket: socket,
       endpoint: endpoint,
       hello: false,
       description: %{},
       listening: MapSet.new(),
       route: :home,
       form: %{},
       pending: %{}
     }}
  end

  @impl true
  def handle_info(:go, state) do
    :ok = :inet.setopts(state.socket, active: true)
    {:noreply, state}
  end

  def handle_info({:tcp, _socket, line}, state) do
    case JSON.decode(line) do
      {:ok, %{"op" => op} = message} ->
        handle_op(op, message, state)

      _ ->
        {:noreply, notice(state, "error", "Control could not read: #{String.slice(line, 0, 80)}")}
    end
  end

  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  def handle_info({:atlas_bus, %Envelope{class: class, id: id} = envelope, content}, state)
      when is_map_key(state.pending, id) and class in ["stored", "refused"] do
    {pending, rest} = Map.pop(state.pending, id)
    Process.cancel_timer(pending.timer)
    state = %{state | pending: rest}

    # A key this client made up was taken by someone else: try the next one.
    retry? =
      content["code"] in ["exists", "reserved"] and pending.retry != nil and
        pending.retry.tries < @key_tries

    case class do
      "stored" ->
        state = %{state | form: %{}}

        text =
          case pending do
            %{content: %{"op" => "create", "key" => key}, retry: %{skipped: [_ | _] = skipped}} ->
              "Stored as #{key} (position #{envelope.position}); " <>
                "#{Enum.join(skipped, ", ")} #{if length(skipped) == 1, do: "was", else: "were"} taken."

            %{content: %{"op" => "create", "key" => key}} ->
              "Stored as #{key} (position #{envelope.position})."

            _ ->
              "Stored by State (position #{envelope.position})."
          end

        state = notice(state, "ok", text)
        {:noreply, show(state, pending.after, "stored", envelope.position)}

      "refused" when retry? ->
        {:noreply, retry_create(state, pending)}

      "refused" ->
        reasons = content["reasons"] || ["refused"]

        if Pages.form?(state.route) do
          form = Map.put(state.form, :errors, reasons)
          state = notice(state, "error", "State refused it; the form says why.")
          {:noreply, show(%{state | form: form}, state.route, "refused", nil)}
        else
          {:noreply, notice(state, "error", "State refused: " <> Enum.join(reasons, "; "))}
        end
    end
  end

  # A hint: a fact of some kind was stored, by anyone.
  def handle_info({:atlas_bus, %Envelope{class: "stored"} = envelope, content}, state) do
    if Pages.shows?(state.route, state.description, envelope.kind) do
      if Pages.form?(state.route) do
        {:noreply,
         notice(
           state,
           "info",
           "#{content["key"]} was changed elsewhere (position #{envelope.position})."
         )}
      else
        {:noreply, show(state, state.route, "hint", envelope.position)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:atlas_bus, _envelope, _content}, state), do: {:noreply, state}

  def handle_info({:resend, id}, state) do
    case state.pending[id] do
      nil ->
        {:noreply, state}

      pending ->
        :ok = AtlasBus.send(pending.envelope, pending.content)
        wait = min(pending.wait * 2, @last_resend)
        timer = Process.send_after(self(), {:resend, id}, wait)
        state = put_in(state.pending[id], %{pending | wait: wait, timer: timer})
        {:noreply, notice(state, "pending", "No answer from State yet; sent again.")}
    end
  end

  # Protocol

  defp handle_op("hello", message, state) do
    environment = AtlasBus.environment()

    if message["env"] == environment do
      send_client(state, %{
        "op" => "welcome",
        "env" => environment,
        "spec" => AtlasControl.Blocks.version()
      })

      state = describe(%{state | hello: true})
      {:noreply, show(state, :home, "open", nil)}
    else
      send_client(state, %{
        "op" => "bye",
        "text" => "This is Control #{environment}; it does not serve #{inspect(message["env"])}."
      })

      {:stop, :normal, state}
    end
  end

  defp handle_op(_op, _message, %{hello: false} = state),
    do: {:noreply, notice(state, "error", "Say hello first.")}

  defp handle_op("open", %{"to" => to}, state) do
    {:noreply, show(%{state | form: %{}}, route(to, state), "open", nil)}
  end

  defp handle_op("refresh", _message, state) do
    state = describe(state)

    if Pages.form?(state.route),
      do: {:noreply, state},
      else: {:noreply, show(state, state.route, "reconcile", nil)}
  end

  defp handle_op("submit", %{"to" => to} = message, state) do
    raw = Map.new(message["values"] || %{}, fn {k, v} -> {k, to_string(v)} end)
    {:noreply, submit(route(to, state), raw, state)}
  end

  defp handle_op(op, _message, state),
    do: {:noreply, notice(state, "error", "Unknown op #{inspect(op)}")}

  defp route(to, state), do: to |> Pages.route() |> Pages.resolve(state.description)

  # Writes

  defp submit({:new, kind} = route, raw, state), do: create(route, kind, raw, %{}, state)

  defp submit({:new, kind, {relation, parent}} = route, raw, state),
    do: create(route, kind, raw, %{relation => [parent]}, state)

  defp submit({:edit, kind, key} = route, raw, state) do
    # The property the id was made from is shown, never changed.
    spec = spec(state, kind)
    values = Pages.values_for(spec, Map.drop(raw, List.wrap(Pages.id_property(spec))))

    content = %{
      "op" => "change",
      "key" => key,
      "values" => values,
      "version" => state.form[:version]
    }

    put_fact(
      %{state | route: route, form: Map.put(state.form, :values, raw)},
      kind,
      content,
      {:item, kind, key}
    )
  end

  defp submit({:delete, kind, key} = route, _raw, state) do
    answer = ask(kind, %{"key" => key})

    held =
      Pages.children(state.description, kind, answer)
      |> Enum.reject(fn {_, keys} -> keys == [] end)

    case answer do
      %{"fact" => %{"version" => version}} when held == [] ->
        content = %{"op" => "delete", "key" => key, "values" => %{}, "version" => version}

        put_fact(
          %{state | route: route},
          kind,
          content,
          Pages.after_delete(state.description, kind, answer)
        )

      _ ->
        show(state, route, "open", nil)
    end
  end

  defp submit(_route, _raw, state), do: notice(state, "error", "Nothing to submit here.")

  # A new fact gets the next free key of its kind; nobody types one. When two clients make
  # the same key at once, State refuses the second ("exists"), and it tries the next number.
  defp create(route, kind, raw, links, state) do
    spec = spec(state, kind)

    if Pages.id_property(spec),
      do: create_made(route, kind, spec, raw, links, state),
      else: create_numbered(route, kind, spec, raw, links, state)
  end

  # An id made from a property: the same value is the same fact, so a taken key is never
  # retried with another number. When the key cannot be made, nothing goes to State.
  defp create_made(route, kind, spec, raw, links, state) do
    state = %{state | route: route, form: %{values: raw}}

    case Pages.key_for(spec, raw) do
      {:ok, key} ->
        content = new_fact(spec, key, raw, links)
        put_fact(state, kind, content, {:item, kind, key})

      {:error, reason} ->
        state = notice(state, "error", "Not sent: the form says why.")
        show(put_in(state.form[:errors], [reason]), route, "refused", nil)
    end
  end

  defp create_numbered(route, kind, spec, raw, links, state) do
    keys =
      case ask(kind, %{}) do
        %{"facts" => facts} -> Enum.map(facts, & &1["key"])
        _ -> []
      end

    {key, number} = Pages.next_key(spec, keys)
    content = new_fact(spec, key, raw, links)
    state = %{state | route: route, form: %{values: raw}}
    put_fact(state, kind, content, {:item, kind, key}, %{number: number, tries: 1, skipped: []})
  end

  defp new_fact(spec, key, raw, links) do
    content = %{
      "op" => "create",
      "key" => key,
      "values" => Pages.create_values(spec, raw),
      "version" => nil
    }

    if links == %{}, do: content, else: Map.put(content, "links", links)
  end

  defp retry_create(state, pending) do
    kind = pending.envelope.kind
    {key, number} = Pages.next_key(spec(state, kind), [], pending.retry.number)
    content = %{pending.content | "key" => key}
    skipped = pending.retry.skipped ++ [pending.content["key"]]
    retry = %{number: number, tries: pending.retry.tries + 1, skipped: skipped}
    note = "#{pending.content["key"]} is taken; trying #{key}…"
    put_fact(state, kind, content, {:item, kind, key}, retry, note)
  end

  defp put_fact(state, kind, content, after_route, retry \\ nil, note \\ nil) do
    envelope = Envelope.new("fact", kind)
    :ok = AtlasBus.send(envelope, content)
    timer = Process.send_after(self(), {:resend, envelope.id}, @first_resend)

    pending = %{
      envelope: envelope,
      content: content,
      after: after_route,
      retry: retry,
      wait: @first_resend,
      timer: timer
    }

    state = put_in(state.pending[envelope.id], pending)
    notice(state, "pending", note || "Sent to State; waiting until it is stored…")
  end

  # Reads

  defp describe(state) do
    case ask(@description, %{}) do
      %{"description" => description} ->
        kinds = Map.keys(description["entities"] || %{})
        Enum.each(kinds, &AtlasBus.listen/1)
        %{state | description: description, listening: MapSet.new(kinds)}

      _ ->
        notice(
          state,
          "error",
          "State did not answer with the description; showing what Control had."
        )
    end
  end

  defp ask(kind, content), do: ask(kind, content, @read_attempts)

  defp ask(_kind, _content, 0), do: %{"error" => "State did not answer"}

  defp ask(kind, content, attempts) do
    envelope = Envelope.new("read", kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id

    receive do
      {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer} -> answer
    after
      @read_timeout -> ask(kind, content, attempts - 1)
    end
  end

  defp show(state, route, reason, position) do
    answers =
      Enum.map(Pages.reads(route, state.description), fn {kind, content} -> ask(kind, content) end)

    page = Pages.render(route, state.description, answers, state.form)

    # Remember the version a change form was made from, so the change names it.
    form =
      case {route, answers} do
        {{:edit, _, _}, [%{"fact" => %{"version" => version}}]} ->
          Map.put(state.form, :version, version)

        _ ->
          state.form
      end

    as_of = position || Enum.find_value(answers, & &1["position"])

    send_client(state, %{
      "op" => "page",
      "path" => current_path(route),
      "title" => page.title,
      "back" => page.back,
      "blocks" => page.blocks,
      "markup" => page.markup,
      "reason" => reason,
      "position" => as_of,
      "at" => now()
    })

    %{state | route: route, form: form}
  end

  defp current_path(:home), do: "/"
  defp current_path(:unknown), do: "/"
  defp current_path(route), do: Pages.path(route)

  defp spec(state, kind), do: get_in(state.description, ["entities", kind]) || %{}

  defp notice(state, tone, text) do
    send_client(state, %{"op" => "notice", "tone" => tone, "text" => text, "at" => now()})
    state
  end

  defp send_client(state, message) do
    case :gen_tcp.send(state.socket, [JSON.encode!(message), "\n"]) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("Control could not reach its client: #{inspect(reason)}")
    end
  end

  defp now, do: NaiveDateTime.local_now() |> NaiveDateTime.to_time() |> Time.to_iso8601()
end
