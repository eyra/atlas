# Try UC-Atlas-19: See what the agent did

What you can do: see every request you made with `:`, what became of it and each step of its plan. From an item the agent made or changed, reach the step and the request that caused it. Everything the agent does is kept as facts in State, like any other change, so it is there after a restart and can be overruled (IS-Atlas-46, next).

## Start

```sh
atlas tui --env test
```

## Try

| Step | Keys | What you should see |
|---|---|---|
| A request | on a scene with a description: `:`, `propose use cases from this scene's description`, `enter`; drop one step with `space`, then `enter` | The plan runs, as in UC-Atlas-17. |
| What the agent did | `esc` back to the start page, then `w` | **Agent requests**, newest first. Each row has its id (`RQ-Atlas-NN`), your request and its outcome: Done, Done without asking, Stopped, Refused, Cancelled. |
| One request | `enter` on it | Its page: the page you asked it on, who planned it (`claude -p`), its outcome, what the agent said, and **Steps**. Each step has its form's title and its state: Stored, Refused, Dropped or Not run. There is no key to create, update or delete it: only the agent writes this record. |
| One step | `enter` on a step | The values it gave, what it made (`UC-Atlas-NN`) and, for a change, the values it replaced. |
| From the item | open the use case the agent made | Its references have **What the agent did here**, with the step that made it. `enter` on it, then the step's request. |
| Cancelled | ask again, then `esc` | It is kept too, as Cancelled, at the top of the list. |

The same from the command line: `atlas list agent_request --env test`, `atlas get RQ-Atlas-NN --env test`.

## How it works

- **The record is described in rela like any kind:** an *agent request* (`RQ-Atlas-NN`) and an *agent step* under it (`ST-Atlas-NN`), in `rela/schema.yaml`. `rela/atlas.json` says what Control and the agent do with them, as data:
  - `agent`: the kinds hold the agent's record. The agent never offers them as tools.
  - `start`: requests are not on the start page; `w What the agent did` is. When the start page becomes My work plus Scenes (SC-Atlas-06), this is the line to change.
  - `order`: newest first.
  - `by_hand`: no keys to create, update or delete them.
  - `cause` on a step's `made`: an item's page lists the steps that made or changed it.
  - `add: false` on the steps of a request: no key to add one.
- **The agent writes the record through Control**, like any client:
  - the request once its plan is made;
  - each step that ran, was refused, dropped or not run, with the key it made or changed and the values it replaced;
  - the outcome at the end.
- **If keeping the record fails**, the TUI says so in a notice. It never makes the agent do more or less.

## What changed for this

- **rela:** the two kinds, their relation and the rules above.
- **Control:** the generic rules `start`, `order`, `by_hand`, `cause` and `add`. `/_kinds` also says which kinds hold the agent's record.
- **The agent:** `AtlasAgent.Record`. `atlas get` reads the exact values of a kind without an update key too.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-19.exs`.
- **Prod:** rela reads `schema.yaml` when it starts, so prod's rela needs a restart for the new kinds.
