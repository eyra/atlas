# Try UC-Atlas-27: Every fact has an owner, and Flow moves it

This guide grows with the use case, one section per issue.

## IS-Atlas-52: the owner, `assigned_to`

This guide grows with the use case. IS-Atlas-52: the owner is an association in rela, `assigned_to`. It goes from every assignable kind (scene, use case, issue, pull request) to a person or an agent, one at most. The link has no attributes: when, by whom and why are the fact that set it, and pages and `atlas get` show them with it. IS-Atlas-53 (Flow) moves owners later.

### Try

In prod, after the migration below, every fact has an owner:

| Step | Where | What you should see |
|---|---|---|
| An owner | `atlas get UC-Atlas-01 --env prod` | `Assigned to: coordinator (since 3 Nov …, by migration: owner introduced)`, and under it the list **Assigned to** with `coordinator  Agent`. `--json` gives `origins["Assigned to"]`: `since`, `by` and `cause`. |
| On its page | any scene, use case, issue or pull request in the TUI | **Assigned to** in the content, with since, by and cause, and in the references, the owner as a row. |
| The owner's page | `enter` on that row, or `atlas get coordinator --env prod` | **Agent coordinator**, with what is assigned to it, one list per kind: **Assignments: Scenes**, **Assignments: Use cases**, … Melle's page (`atlas get melle`) the same for Melle. |
| Change it | `atlas set UC-Atlas-01 assigned_to=melle --cause "all 12 issues completed" --env test`, or `u` on the page (**Assigned to**, a person or an agent, `ctrl-s`) | One owner, the new one, with its own since, by and cause. The earlier owner stays in the facts as history. |
| Only who can own | `atlas set UC-Atlas-01 assigned_to=nobody --env test` | Refused: `nobody is not a person or agent`. |

Try changes in test (`--env test`), not prod: prod is real data.

### The prod data: `atlas migrate-owner`

Every fact that exists gets the coordinator as its owner, one fact each, with the cause "owner introduced". The coordinator runs it after the merge, once prod's rela has restarted on the new description:

```sh
atlas migrate-owner --env prod --dry-run   # prints every step; writes nothing
atlas migrate-owner --env prod             # writes them through Control, as the migration
atlas migrate-owner --env prod --dry-run   # again: 0 steps
```

What it does:
1. It makes the agent `coordinator` (Coordinator) when there is none.
2. It sets `assigned_to` coordinator on every fact of a kind in `assigned_to`'s `from` that has no owner yet. It reads that list from rela's description, so a kind added there is included.

It reads rela read-only and writes only through Control. A fact that has an owner keeps it, so a second run does nothing.

Tried on a private instance with prod's shape (prod's facts copied in with reads only): 147 steps (the agent, and 6 scenes, 34 use cases, 69 issues and 37 pull requests) in 49 s, then 0.

### How it works

- **rela's description:**
  - `rela/schema.yaml` has an `agent` kind next to `person` (made from a name, not on the start page; `rela/atlas.json`).
  - It has `assigned_to` from scene, use case, issue and pull request to person and agent, with `max_outgoing: 1` and the inverse `assignments`.
  - A kind is assignable by being in `assigned_to`'s `from`; adding one is a change to the description only.
- **A relation to several kinds:**
  - rela links each key with its kind, but answers only the keys. State finds out which kind a key is by reading it in each kind the relation points at, both on a write and when it answers one fact (`link_kinds`).
  - A key of none is refused. Control opens it as that kind, and offers the facts of every such kind on the links page.
- **A relation from several kinds:** the page it points at has one list per kind (`Assignments: Scenes`, …). As for any association, a list shows only when it has something.
- **A key without an id prefix** (`melle`, `coordinator`): when more than one kind has no prefix, Control asks State which one has it, for `atlas get <key>`.
- **No kind is named** in BEAM, the TUI or the agent. The words a page shows ("Assigned to", "Assignments") are the relation's label and inverse label in the description, so naming them otherwise (d-0022) is a one-line change there.

### What changed for this

- **rela:** `agent`; `assigned_to`.
- **State:** relations to several kinds; `link_kinds` in a fact's answer.
- **Control:** lists per kind for a relation from several; rows and the links page for one to several; keys without a prefix.
- **tools/plan:** `AtlasPlan.Owner` and `atlas migrate-owner`.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-27-owner.exs`.
- **Prod:** restart rela (it reads `schema.yaml` when it starts) and the core, then run the migration.

## IS-Atlas-53: Flow moves a fact on (the first slice)

What you can see: a use case or scene says what its owner is expected to do next, and Flow keeps that true by itself. While not all under it is completed it says `Build it`. Once all is, it says `Test it`. Once it is accepted, nothing is expected. Once it is reopened, it says `Rework: <the note>`. Flow never completes anything: done is accepted (UC-Atlas-32). Nobody types what is expected; it is a fact Flow stores, with its cause.

The owner itself comes with IS-Atlas-52 (`assigned_to`). This slice already knows who it is (`melle` to test, the coordinator to build and rework) and writes it once that association exists.

### Start

```sh
atlas tui --env test
```

### Try

| Step | Keys / command | What you should see |
|---|---|---|
| A use case with an open issue | `c` a scene, `c` a use case in it, `c` an issue in that | The use case's page: `Expected  Build it`; the scene says the same. |
| Its pull request merges | link a pull request to the issue and merge it on GitHub (in the e2e: the stand-in) | Within a connector round its row shows Done, and within a second after that the use case says `Expected  Test it`, in every open TUI. Its progress says `To test · 1/1`: Flow does not accept it. |
| Accept | `a`, `y` | `Expected` is gone: done, nothing is expected of anyone. |
| Reopen | `a` (Reopen), a note, `ctrl-s` | `Expected  Rework: <the note>`. |
| Rework starts | `c` a new issue under it | `Expected  Build it` again. |

In prod, after the merge and a restart, every open scene and use case gets its `Expected`, one change each, by `flow`, with the cause, such as `Flow test_and_accept: all under it is completed → melle`.

### How it works

- **The definition** is data in `rela/atlas.json`, under `flows`. `test_and_accept` runs on scenes and use cases and writes `expected`. Its states are in order, and a fact is in the first that holds:
  1. `done` (completed);
  2. `rework` (the newest fact about `accepted_by` removed it, and nothing came under the fact since; `{note}` is that fact's cause);
  3. `to_test` (its progress is `to_test`);
  4. `building` (otherwise).

  Each open state names its owner, what is expected, why, and its next states.
- **The check:** State checks every definition before anyone runs it (`AtlasState.Flows`). Every state that is not done has an owner and a way out to a next state, every state reaches done, the last state holds when no other does, and the kinds, field and owner relation exist. The description State answers carries `flow_problems`, and Flow runs only a sound definition. A unit test checks the definitions in `rela/atlas.json`, so CI refuses an unsound one.
- **The engine:** Flow is its own BEAM application, `atlas_flow`, beside Bus, State and Control, and it talks only over the Bus.
  - It runs one supervised process per open fact (`AtlasFlow.Item`), registered by kind and key, so a second one cannot start. Each process has a timer in every state (every minute; `flow.tick_seconds` in the environment's settings, or a state's `every_seconds`).
  - On its timer, and at once on any hint, a process reads its fact and what hangs under it, works out the state, and stores only what differs (safe to repeat). It stops once its fact is done or gone. It keeps nothing State does not hold, so a crashed process is started again and goes on from State.
  - At boot, and every round, the engine starts a process for every open fact without one. A hint of a new fact starts its process at once. Nobody depends on a hint.
- No kind is named in BEAM, TUI or agent code; the boundary test covers `atlas_flow` too.

`e2e/scenarios/uc-atlas-27.exs` follows these steps on a private instance.
