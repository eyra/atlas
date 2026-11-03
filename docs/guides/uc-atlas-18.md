# Try UC-Atlas-18: Run, follow and stop the steps

What you can do: after `enter` on a plan (UC-Atlas-17), watch each step go, one at a time, in both TUIs, and stop the agent with `esc` before its next step. The steps already stored stay.

## Start

```sh
atlas tui --env test
```

Run it again in a second terminal for TUI 2, on the same scene.

## Try

| Step | Keys | What you should see |
|---|---|---|
| A plan | on a scene whose description lists a few use cases: `:`, `propose use cases from this scene's description`, `enter` | `Proposed: N steps`. |
| Run | `enter` | The step being run shows `[…]`. Each stored step turns `[✓] … Stored as UC-Atlas-NN.`, and the title counts: `Running: 1 of N stored`. TUI 2 shows each use case by hint as it is stored. At the end: `Done: N of N stored`. |
| Stop | ask again, `enter`, then `esc` while it runs | `Stopping after this step…`, then `Stopped: 1 of N stored`. The steps not run show `[-] … Not run: stopped before it.` Only the stored ones are in the scene. |

Nothing is rolled back by itself: undoing a stored step is an overrule (UC-Atlas-19).

## How it works

The agent (`atlas steer`) runs one step at a time and reads its messages between steps, so a stop is seen before the next step. It waits `agent.step_pause_ms` between steps, set in `env/<env>.json` and 0 when unset. That is long enough to follow a run and to stop it. The end-to-end test uses 500.

## What changed for this

- **The agent:** the pause between steps; steps not run say why.
- **The TUI:** "Stopping after this step…" is cleared when the plan ends.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-18.exs`.
