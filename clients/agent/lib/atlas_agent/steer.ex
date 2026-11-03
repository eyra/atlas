defmodule AtlasAgent.Steer do
  @moduledoc """
  `atlas steer --env <env>`: the agent behind the TUI's `:` (UC-Atlas-17). A client of
  Control like any other: it reads pages and fills forms through Control, with the tools
  of `AtlasAgent.Tools`, and knows no entity. The TUI starts it as a child process and
  talks to it in JSON lines, one message per line: from the TUI on stdin, to it on stdout.

  From the client:

  | Message | Meaning |
  |---|---|
  | `{"op":"ask","request","on"}` | Plan `request`, made on the page at path `on`. Writes nothing. |
  | `{"op":"run","steps":[{"n","values"}]}` | Run these steps of the proposed plan, in this order, with these values (only the inputs a step has). The rest are dropped. |
  | `{"op":"cancel"}` | Drop the plan, also while it is being made. |
  | `{"op":"stop"}` | Stop a run before its next step; stored steps stay. |

  When State refuses a step, the run stops there, and the agent asks the planner what
  next, telling it what was stored, what was refused and why, and what was not run
  (UC-Atlas-18). The answer is a new plan, with `before` saying what happened; like any
  plan it runs only on `run`. The agent never retries a refused step by itself.

  A small plan runs without asking (UC-Atlas-18): at most `agent.ask_above` steps (1 by
  default; 0 asks always), every one of them able to run, none deleting. A plan made
  after a refusal always asks. Such a plan shows like an accepted one, and its title says
  it ran without asking.

  To the client: `{"op":"plan","block":<a plan block>}`, the plan as it is now, after
  every change (the contract's `plan` block, with its `step`s), and `{"op":"notice",
  "tone","text"}`.

  Nothing is written except by `run`, and only the steps of the plan it was given, so
  nothing the planner answers runs before a person accepts it. Each plan and each run
  has a Control connection of its own, closed when it is done.

  A run goes one step at a time, and waits `agent.step_pause_ms` (from the settings, 0 by
  default) before the next, so a person can follow it. A stop is seen before the next
  step, also during that wait (UC-Atlas-18); the steps not run say so.
  """

  alias AtlasAgent.{Client, Plan}

  def main(env) do
    case AtlasAgent.settings(env) do
      {:ok, settings} ->
        me = self()
        spawn_link(fn -> read(me) end)
        loop(%{env: env, settings: settings, plan: nil, task: nil, run: nil})

      {:error, text} ->
        emit(%{"op" => "notice", "tone" => "error", "text" => text})
        2
    end
  end

  defp read(parent) do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        send(parent, {:line, line})
        read(parent)

      _eof ->
        send(parent, :eof)
    end
  end

  defp loop(state) do
    receive do
      {:line, line} ->
        case JSON.decode(line) do
          {:ok, %{"op" => op} = message} -> loop(handle(op, message, state))
          _ -> loop(state)
        end

      {ref, result} when is_reference(ref) and state.task != nil and ref == state.task.ref ->
        Process.demonitor(ref, [:flush])
        loop(planned(result, %{state | task: nil}))

      {:DOWN, ref, :process, _, reason} when state.task != nil and ref == state.task.ref ->
        loop(planned({:error, "the planner stopped: #{inspect(reason)}"}, %{state | task: nil}))

      :step ->
        loop(step(state))

      :eof ->
        if state.task, do: Task.shutdown(state.task, :brutal_kill)
        if state.run, do: Client.close(state.run.client)
        0
    end
  end

  # Asking

  defp handle("ask", %{"request" => request, "on" => on}, state) when is_binary(request),
    do: plan(drop(state), request, on, nil)

  defp handle("cancel", _message, %{plan: nil} = state), do: state

  defp handle("cancel", _message, %{run: nil} = state) do
    state = drop(state)
    show(%{state | plan: %{state.plan | state: "cancelled"}}) |> Map.put(:plan, nil)
  end

  defp handle("run", %{"steps" => chosen}, %{plan: %{state: "proposed"} = plan} = state)
       when is_list(chosen) do
    by_n = Map.new(plan.steps, &{&1["n"], &1})
    order = for %{"n" => n} <- chosen, Map.has_key?(by_n, n), do: n
    blocked = for n <- order, by_n[n]["problem"], do: n

    cond do
      order == [] ->
        notice(state, "info", "No step is kept; nothing to run.")

      blocked != [] ->
        notice(state, "error", "Step #{Enum.join(blocked, ", ")} cannot run; drop it first.")

      true ->
        values = for %{"n" => n} = c <- chosen, into: %{}, do: {n, c["values"] || %{}}
        start(state, order, values)
    end
  end

  defp handle("run", _message, state),
    do: notice(state, "error", "There is no proposed plan to run.")

  defp handle("stop", _message, %{run: run} = state) when run != nil,
    do: %{state | run: %{run | stop: true}}

  defp handle(_op, _message, state), do: state

  # Run the steps `order` of the proposed plan, with `values` by step number.
  defp start(%{plan: plan} = state, order, values) do
    steps =
      Enum.map(plan.steps, fn step ->
        if step["n"] in order,
          do: edited(step, values[step["n"]] || %{}),
          else: Map.put(step, "state", "dropped")
      end)

    case AtlasAgent.connect(state.env) do
      {:ok, client} ->
        send(self(), :step)
        run = %{client: client, order: order, stop: false}
        show(%{state | run: run, plan: %{plan | state: "running", steps: steps}})

      {:error, text} ->
        notice(state, "error", text)
    end
  end

  # Whether a plan may run without asking: small, every step able to run, none deleting,
  # and not a plan made after a refusal.
  defp by_itself?(state, plan) do
    limit = get_in(state.settings, ["agent", "ask_above"]) || 1

    plan.steps != [] and length(plan.steps) <= limit and plan.before == nil and
      Enum.all?(plan.steps, &(&1["state"] == "proposed" and &1["tool"] != "delete"))
  end

  defp plan(state, request, on, before) do
    %{env: env, settings: settings} = state

    task =
      Task.async(fn ->
        with {:ok, client} <- AtlasAgent.connect(env) do
          try do
            Plan.make(client, settings, on, request, before)
          after
            Client.close(client)
          end
        end
      end)

    plan = %{
      request: request,
      on: on,
      before: before && before["text"],
      by_itself: false,
      state: "planning",
      summary: nil,
      by: nil,
      steps: []
    }

    show(%{state | task: task, plan: plan})
  end

  defp planned({:ok, made}, %{plan: plan} = state) when plan != nil do
    steps =
      Enum.map(made["steps"], fn step ->
        Map.put(step, "state", if(step["problem"], do: "blocked", else: "proposed"))
      end)

    plan = %{plan | state: "proposed", summary: made["summary"], by: made["by"], steps: steps}

    if by_itself?(state, plan) do
      plan = Map.put(plan, :by_itself, true)
      start(%{state | plan: plan}, Enum.map(steps, & &1["n"]), %{})
    else
      show(%{state | plan: plan})
    end
  end

  defp planned({:error, text}, %{plan: plan} = state) when plan != nil do
    show(%{state | plan: %{plan | state: "failed", summary: text}})
  end

  defp planned(_result, state), do: state

  # A step's values as the person left them: only the inputs it has.
  defp edited(step, values) do
    names = Enum.map(step["inputs"], & &1["name"])
    values = Map.take(values || %{}, names)

    inputs =
      Enum.map(step["inputs"], &Map.put(&1, "value", Map.get(values, &1["name"], &1["value"])))

    Map.merge(step, %{"values" => Map.merge(step["values"], values), "inputs" => inputs})
  end

  # Running: one step per message, so a stop that came in meanwhile is seen in between.

  defp step(%{run: nil} = state), do: state

  defp step(%{run: %{order: []}} = state), do: finish(state, "done")

  defp step(%{run: %{stop: true}} = state), do: finish(state, "stopped")

  defp step(%{run: %{order: [n | rest]} = run} = state) do
    state = show(put_step(state, n, %{"state" => "running"}))
    step = Enum.find(state.plan.steps, &(&1["n"] == n))

    case write(run.client, step) do
      {:ok, key} ->
        Process.send_after(self(), :step, pause(state))
        state = put_step(state, n, %{"state" => "stored", "detail" => "Stored as #{key}."})
        show(%{state | run: %{run | order: rest}})

      {:refused, reasons} ->
        state = put_step(state, n, %{"state" => "refused", "detail" => Enum.join(reasons, "; ")})
        state |> Map.put(:run, %{run | order: rest}) |> finish("failed") |> what_next()

      {:error, text} ->
        state = put_step(state, n, %{"state" => "refused", "detail" => text})
        finish(%{state | run: %{run | order: rest}}, "failed")
    end
  end

  # After a refusal: what happened, for the planner and for the person, and a new plan.
  defp what_next(%{plan: plan} = state) do
    shown = fn step -> Map.take(step, ~w(n label tool kind in key values detail)) end
    stored = for %{"state" => "stored"} = s <- plan.steps, do: shown.(s)
    not_run = for %{"state" => "not_run"} = s <- plan.steps, do: shown.(s)
    refused = Enum.find(plan.steps, &(&1["state"] == "refused"))

    text =
      Enum.join(
        [
          "Step #{refused["n"]} (#{refused["label"]}) was refused: " <>
            String.trim_trailing(refused["detail"] || "", ".") <> ".",
          if(stored != [],
            do: "Stored before it: " <> Enum.map_join(stored, ", ", &"step #{&1["n"]}") <> ".",
            else: "Nothing was stored."
          ),
          if(not_run != [],
            do: "Not run: " <> Enum.map_join(not_run, ", ", &"step #{&1["n"]}") <> ".",
            else: nil
          )
        ]
        |> Enum.reject(&is_nil/1),
        " "
      )

    before = %{
      "text" => text,
      "stored" => stored,
      "refused" => shown.(refused),
      "not_run" => not_run
    }

    plan(state, plan.request, plan.on, before)
  end

  defp write(client, %{"tool" => "put"} = step),
    do: AtlasAgent.put(client, step["kind"], step["values"], step["in"])

  defp write(client, %{"tool" => "set"} = step),
    do: AtlasAgent.set(client, step["key"], step["values"])

  defp finish(%{run: run, plan: plan} = state, outcome) do
    Client.close(run.client)

    steps =
      Enum.map(
        plan.steps,
        &if(&1["n"] in run.order,
          do: Map.merge(&1, %{"state" => "not_run", "detail" => not_run(outcome)}),
          else: &1
        )
      )

    show(%{state | run: nil, plan: %{plan | state: outcome, steps: steps}})
  end

  defp not_run("stopped"), do: "Not run: stopped before it."
  defp not_run(_outcome), do: "Not run: an earlier step was refused."

  defp pause(state), do: get_in(state.settings, ["agent", "step_pause_ms"]) || 0

  defp put_step(%{plan: plan} = state, n, change) do
    steps = Enum.map(plan.steps, &if(&1["n"] == n, do: Map.merge(&1, change), else: &1))
    %{state | plan: %{plan | steps: steps}}
  end

  defp drop(state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    %{state | task: nil}
  end

  # To the client

  defp show(%{plan: plan} = state) do
    emit(%{"op" => "plan", "block" => block(plan)})
    state
  end

  defp notice(state, tone, text) do
    emit(%{"op" => "notice", "tone" => tone, "text" => text})
    state
  end

  @doc "A plan as the contract's `plan` block (optional props without a value left out)."
  def block(plan) do
    steps =
      for step <- plan.steps do
        compact(%{
          "n" => step["n"],
          "label" => step["label"],
          "state" => step["state"],
          "why" => step["why"],
          "detail" => step["detail"] || step["problem"],
          "inputs" => step["inputs"]
        })
      end

    props =
      compact(%{
        "title" => title(plan),
        "request" => plan.request,
        "state" => plan.state,
        "summary" => plan.summary,
        "by" => plan.by,
        "before" => plan[:before],
        "steps" => steps
      })

    %{"id" => "plan", "type" => "plan", "props" => props}
  end

  defp title(%{by_itself: true, state: s} = plan) when s in ["running", "done"],
    do: title(%{plan | by_itself: false}) <> ", without asking"

  defp title(%{state: "planning"}), do: "Planning…"
  defp title(%{state: "proposed", steps: []}), do: "No steps proposed"
  defp title(%{state: "proposed", steps: steps}), do: "Proposed: #{count(steps, "step")}"
  defp title(%{state: "running"} = plan), do: "Running: #{stored(plan)} of #{kept(plan)} stored"
  defp title(%{state: "done"} = plan), do: "Done: #{stored(plan)} of #{kept(plan)} stored"
  defp title(%{state: "stopped"} = plan), do: "Stopped: #{stored(plan)} of #{kept(plan)} stored"
  defp title(%{state: "failed", steps: []}), do: "No plan"
  defp title(%{state: "failed"} = plan), do: "Refused: #{stored(plan)} of #{kept(plan)} stored"
  defp title(%{state: "cancelled"}), do: "Cancelled; nothing was written"

  defp stored(plan), do: Enum.count(plan.steps, &(&1["state"] == "stored"))
  defp kept(plan), do: Enum.count(plan.steps, &(&1["state"] != "dropped"))

  defp count(list, word),
    do: "#{length(list)} #{word}#{if length(list) == 1, do: "", else: "s"}"

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  defp emit(message), do: IO.puts(JSON.encode!(message))
end
