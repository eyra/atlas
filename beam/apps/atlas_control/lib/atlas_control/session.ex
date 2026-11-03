defmodule AtlasControl.Session do
  @moduledoc """
  One connected client. Speaks Control's protocol (`bff/README.md`) as JSON
  lines over TCP, and reaches State only over the Bus, as its own endpoint.

  - Opening a path reads what the page needs from State and sends the page.
  - A submit becomes a fact. The client is told it waits; the change shows only once
    State has stored it. A fact without an answer is sent again with the same id, after
    5 seconds, then twice as long each time, up to a minute.
  - A hint (a `stored` of a kind on screen) re-reads and sends the page again. A form is
    never redrawn under the user's hands; they get a notice instead.
  - The client asks for a refresh on an interval (it reconciles); a lost hint only delays.
  - Each fact says who sent it (`by`): the user at a TUI (`tui_user` in the environment's
    settings; one for now), `migration` for a migration (which may set what the
    description marks `set_by: migration`), or `agent` for any other client, as its hello
    says.
    A submit may carry a `cause`; it goes with the fact, as does a links form's note.
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
       pending: %{},
       by: "agent",
       by_kind: nil,
       cause: nil
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
          # No form to say why: the page says it (`refused`), for a client without a screen.
          state = notice(state, "error", "State refused: " <> Enum.join(reasons, "; "))
          {:noreply, show(state, state.route, "refused", nil, reasons)}
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

      state = describe(%{state | hello: true, by: actor(message["client"])})
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
    cause = if is_binary(message["cause"]) and message["cause"] != "", do: message["cause"]
    state = submit(route(to, state), raw, %{state | cause: cause})
    {:noreply, %{state | cause: nil}}
  end

  defp handle_op(op, _message, state),
    do: {:noreply, notice(state, "error", "Unknown op #{inspect(op)}")}

  defp route(to, state), do: to |> Pages.route() |> Pages.resolve(state.description)

  # Who is on this session. A TUI is the environment's TUI user for now; anything else is
  # an agent. No sign-in yet: a client is what its hello says.
  defp actor("tui"), do: Application.get_env(:atlas_control, :tui_user) || "agent"
  defp actor("migration"), do: "migration"
  defp actor(_client), do: "agent"

  # Writes

  defp submit({:new, kind} = route, raw, state), do: create(route, kind, raw, %{}, state)

  defp submit({:new, kind, {relation, parent}} = route, raw, state),
    do: create(route, kind, raw, %{relation => [parent]}, state)

  defp submit({:edit, kind, key} = route, raw, state) do
    # The property the id was made from is shown, never changed.
    spec = spec(state, kind)
    {parents, fields} = Map.split(raw, Pages.parent_relations(state.description, kind))
    values = Pages.values_for(spec, Map.drop(fields, List.wrap(Pages.id_property(spec))))
    state = %{state | route: route, form: Map.put(state.form, :values, raw)}
    was = state.form[:parents] || %{}

    with {:ok, links} <- moves(parents, was),
         [] <- over_limits(state, kind, key, links) do
      content = %{
        "op" => "change",
        "key" => key,
        "values" => values,
        "version" => state.form[:version]
      }

      content =
        if links == %{},
          do: content,
          else: Map.merge(content, %{"links" => links, "cause" => moved(links, was)})

      put_fact(state, kind, content, {:item, kind, key})
    else
      {:error, reasons} -> not_sent(state, route, reasons)
      reasons when is_list(reasons) -> not_sent(state, route, reasons)
    end
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

  # The links of one association: exactly the keys named, none removes them.
  defp submit({:links, kind, key, relation} = route, raw, state) do
    state = %{state | route: route, form: Map.put(state.form, :values, raw)}

    keys = Pages.link_keys(raw["to"])

    if Pages.may_link_to?(state.description, relation, state.by, state.by_kind, keys) do
      note = String.trim(raw["note"] || "")
      state = if note != "", do: %{state | cause: note}, else: state
      put_fact(state, kind, link(key, relation, keys), {:item, kind, key})
    else
      show(state, route, "refused", nil)
    end
  end

  # Link the fact to the client itself (Accept), when the page would let it.
  defp submit({:set, kind, key, relation} = route, _raw, state) do
    answers = Enum.map(Pages.reads(route, state.description), fn {k, c} -> ask(k, c) end)

    case Pages.set_problem(state.description, route, answers, state.by, state.by_kind) do
      nil ->
        put_fact(
          %{state | route: route},
          kind,
          link(key, relation, [state.by]),
          {:item, kind, key}
        )

      problem ->
        state = notice(state, "error", problem)
        show(state, route, "refused", nil)
    end
  end

  # Remove the link (Reopen), with the note as its cause.
  defp submit({:remove, kind, key, relation} = route, raw, state) do
    state = %{state | route: route, form: Map.put(state.form, :values, raw)}
    note = String.trim(raw["note"] || "")

    cond do
      not Pages.may_link?(state.description, relation, state.by, state.by_kind) ->
        show(state, route, "refused", nil)

      note == "" ->
        not_sent(state, route, ["a note is required: why it is reopened"])

      true ->
        put_fact(%{state | cause: note}, kind, link(key, relation, []), {:item, kind, key})
    end
  end

  defp submit(_route, _raw, state), do: notice(state, "error", "Nothing to submit here.")

  defp link(key, relation, keys),
    do: %{
      "op" => "change",
      "key" => key,
      "values" => %{},
      "links" => %{relation => keys},
      "version" => nil
    }

  # The parents a change form names that differ from those the fact had: `{:ok, %{relation
  # => [key]}}`. A change moves a fact; it never leaves one without the parent it had.
  defp moves(parents, was) do
    empty = for {relation, ""} <- parents, Map.has_key?(was, relation), do: relation

    if empty == [] do
      {:ok,
       for({relation, parent} <- parents, parent != "", parent != was[relation], into: %{}) do
         {relation, [parent]}
       end}
    else
      {:error, Enum.map(empty, &"#{&1} cannot be empty; choose where it goes")}
    end
  end

  # The cause a move is stored with: "Moved from UC-Atlas-01 to UC-Atlas-30 (in_use_case),
  # by a change in Control".
  defp moved(links, was) do
    changes =
      Enum.map_join(links, "; ", fn {relation, [to]} ->
        "from #{was[relation] || "nothing"} to #{to} (#{relation})"
      end)

    "Moved #{changes}, by a change in Control"
  end

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

    with {:ok, key} <- Pages.key_for(spec, raw),
         [] <- over_limits(state, kind, key, links) do
      content = new_fact(spec, key, raw, links)
      put_fact(state, kind, content, {:item, kind, key})
    else
      {:error, reason} -> not_sent(state, route, [reason])
      reasons when is_list(reasons) -> not_sent(state, route, reasons)
    end
  end

  defp create_numbered(route, kind, spec, raw, links, state) do
    case over_limits(state, kind, nil, links) do
      [] -> create_numbered_free(route, kind, spec, raw, links, state)
      reasons -> not_sent(%{state | route: route, form: %{values: raw}}, route, reasons)
    end
  end

  defp create_numbered_free(route, kind, spec, raw, links, state) do
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

  # A link the description limits (`relations.<name>.limit`) is refused before State sees
  # it while its parent already has as many counted facts as allowed. Links that are
  # there already stay; only a new one (a create, or a move) is checked.
  defp over_limits(state, kind, key, links) do
    closed(state, kind, links) ++
      for {relation, parent} <- Pages.limited(state.description, links),
          problem = limit_problem(state, relation, kind, key, parent),
          problem != nil,
          do: problem
  end

  # A new fact under a parent that is closed to it (accepted: `closes_parent`), by a create
  # or a move, is refused with why.
  defp closed(state, kind, links) do
    for {relation, parents} <- links,
        relation in Pages.parent_relations(state.description, kind),
        [parent_kind] <- [get_in(state.description, ["relations", relation, "to"])],
        parent <- parents,
        %{"fact" => %{} = fact} <- [ask(parent_kind, %{"key" => parent})],
        problem = Pages.closed_problem(state.description, kind, parent_kind, fact),
        problem != nil,
        do: problem
  end

  defp limit_problem(state, relation, kind, key, parent) do
    case ask(kind, %{"linked" => %{relation => parent}}) do
      %{"facts" => children} ->
        Pages.over_limit(state.description, relation, kind, key, parent, children)

      %{"error" => error} ->
        "#{error}; could not check how many #{parent} has"
    end
  end

  defp not_sent(state, route, reasons) do
    state = notice(state, "error", "Not sent: the form says why.")
    show(put_in(state.form[:errors], reasons), route, "refused", nil)
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
    content = Map.put(content, "by", state.by)
    content = if state.cause, do: Map.put(content, "cause", state.cause), else: content
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
        state = %{state | description: description, listening: MapSet.new(kinds)}
        %{state | by_kind: actor_kind(state)}

      _ ->
        notice(
          state,
          "error",
          "State did not answer with the description; showing what Control had."
        )
    end
  end

  # The kind of fact the client is (the user at a TUI), or nil (an agent, a migration):
  # the kind whose ids its key fits, when a fact with that key exists.
  defp actor_kind(state) do
    case Pages.resolve({:item, "_", state.by}, state.description) do
      {:item, kind, key} ->
        case ask(kind, %{"key" => key}) do
          %{"fact" => %{}} -> kind
          _ -> nil
        end

      _ ->
        nil
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

  defp show(state, route, reason, position, refused \\ nil) do
    answers =
      Enum.map(Pages.reads(route, state.description), fn {kind, content} -> ask(kind, content) end)

    form = Map.merge(state.form, %{by: state.by, by_kind: state.by_kind})
    page = Pages.render(route, state.description, answers, form)

    # Remember the version a change form was made from, so the change names it, and the
    # parents the fact had, so only a parent that differs moves it.
    form =
      case {route, answers} do
        {{:edit, kind, _}, [%{"fact" => %{"version" => version} = fact} | _]} ->
          parents = Pages.parent_values(state.description, kind, fact)
          Map.merge(state.form, %{version: version, parents: parents})

        _ ->
          state.form
      end

    as_of = position || Enum.find_value(answers, & &1["position"])

    send_client(
      state,
      %{
        "op" => "page",
        "path" => current_path(route),
        "title" => page.title,
        "back" => page.back,
        "blocks" => page.blocks,
        "markup" => page.markup,
        "reason" => reason,
        "position" => as_of,
        "at" => now()
      }
      |> then(&if(refused, do: Map.put(&1, "refused", refused), else: &1))
    )

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
