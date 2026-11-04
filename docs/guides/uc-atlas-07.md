# Try UC-Atlas-07: Run and supervise an agent

This guide grows with the use case. IS-Atlas-15: Runtime, a BEAM application next to Bus, State, Flow and Control. It runs the turns of the agents its machine runs: a fact owned by such an agent gets a turn, and the turn keeps its lease while the agent shows activity (architecture v4, section 3, W1, W2, W4). Every start, renewal and end is a fact in State with its cause, by `runtime`. Flow decides who owns what; Runtime only runs turns for owners.

No real agent runs yet: the agent behind a turn is a port, and this issue has only the stand-in, `stub`. IS-Atlas-18 adds Claude Code on the MacBook.

## Where it runs

Runtime runs where the environment's settings give it agents (`runtime` in the settings file):

```json
"runtime": {
  "machine": "macbook",
  "agents": { "runner": { "port": "stub" } },
  "stub_dir": "~/…/stub",
  "silence_seconds": 600, "lease_seconds": 60, "round_seconds": 60, "max_seconds": 7200
}
```

Test and prod have no `runtime` yet, so Runtime there does nothing; IS-Atlas-18 gives the MacBook its agents. The end-to-end test's private instance runs one, `runner`, with a silence limit of 3 s.

## Try (on a private instance, as the e2e does)

| Step | Command | What you should see |
|---|---|---|
| An agent's fact | `atlas put agent --name Runner`, then `atlas set UC-Atlas-NN assigned_to=runner --cause "runner builds it"` | Within a second, a turn `TU-AS-UC-Atlas-NN-1`: `atlas get TU-AS-UC-Atlas-NN-1` shows State Running, Machine, Lease until, and Activity `stub step N`, renewed every second while the stub is active. |
| On its page | the use case's Assignment (`AS-UC-Atlas-NN`, in its references) | **Turns**: the turn, by hint. |
| Silent | `echo silent > <stub_dir>/runner` | After the silence limit: State Ended, Why `silent for 3 s: no activity since …`. Then a new turn, `-2`, since runner still owns it. |
| A crash | `echo crash > <stub_dir>/runner` | The turn ends: `the agent crashed: :crashed`, and the next starts. |
| Another owner | `atlas set UC-Atlas-NN assigned_to=coordinator --cause …` | The turn ends: `AS-UC-Atlas-NN is no longer runner's to work on`, and no new one starts. |
| Restarted | stop the core while a turn runs, start it again | The turn State had running ends: `no process runs it on <machine> any more (Runtime restarted)`, and a new one starts. |

## How it works

- **rela:** a `turn` kind:
  - `state` (running or ended), `machine`, `lease_until`, `activity` and `why`;
  - `turn_on` to the Assignment (the fact Flow writes on) and `turn_by` to the agent.
- **rela/atlas.json:** `runtime.turn` names the kind, its fields and relations, and its key (`TU-{on}-{n}`). Runtime names no kind. The kind is not by hand: no keys to make one, and the agent's tools leave it out.
- **Runtime (`atlas_runtime`):**
  - The **engine** reconciles every round and at once on a hint. A turn running in State on this machine without a process is ended; a turn whose fact is no longer its agent's (or no longer open: Flow has no state for it) is ended; an owned open fact without a turn gets one, one turn per agent at a time.
  - Each **turn** is a process: it starts the agent through its port, writes the turn, renews the lease while there is activity, and writes its end.
  - The **port** (`AtlasRuntime.Agent`): `start` and `stop`, activity and the end as messages, a crash as the agent's process exiting. The stub reads its mode from a file.
  - It talks only over the Bus, under the same boundary tests as the other layers.

## What changed for this

- **rela:** `turn`, `turn_on`, `turn_by`. **rela/atlas.json:** `runtime.turn`, the turn kind's marks.
- **BEAM:** `atlas_runtime`, in the release; `runtime` settings; the boundary test covers it.
- **Control:** the kinds page says when a kind is not by hand. **Agent:** such kinds are no tools.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-07.exs`; the private instance runs Runtime with the stub agent `runner`.
- **Prod at merge:** `atlas restart` (rela gets the turn kind). Runtime does nothing there until IS-Atlas-18 gives a machine its agents.
