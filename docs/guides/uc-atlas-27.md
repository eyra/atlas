# Try UC-Atlas-27: Flow moves a fact on (IS-Atlas-53, the first slice)

What you can see: a use case or scene says what its owner is expected to do next, and Flow keeps that true by itself. While not all under it is completed it says `Build it`. Once all is, it says `Test it`. Once it is accepted, nothing is expected. Once it is reopened, it says `Rework: <the note>`. Flow never completes anything: done is accepted (UC-Atlas-32). Nobody types what is expected; it is a fact Flow stores, with its cause.

The owner itself comes with IS-Atlas-52 (`assigned_to`). This slice already knows who it is (`melle` to test, the coordinator to build and rework) and writes it once that association exists.

## Start

```sh
atlas tui --env test
```

## Try

| Step | Keys / command | What you should see |
|---|---|---|
| A use case with an open issue | `c` a scene, `c` a use case in it, `c` an issue in that | The use case's page: `Expected  Build it`; the scene says the same. |
| Its pull request merges | link a pull request to the issue and merge it on GitHub (in the e2e: the stand-in) | Within a connector round its row shows Done, and within a second after that the use case says `Expected  Test it`, in every open TUI. Its progress says `To test · 1/1`: Flow does not accept it. |
| Accept | `a`, `y` | `Expected` is gone: done, nothing is expected of anyone. |
| Reopen | `a` (Reopen), a note, `ctrl-s` | `Expected  Rework: <the note>`. |
| Rework starts | `c` a new issue under it | `Expected  Build it` again. |

In prod, after the merge and a restart, every open scene and use case gets its `Expected`, one change each, by `flow`, with the cause, such as `Flow test_and_accept: all under it is completed → melle`.

## How it works

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
