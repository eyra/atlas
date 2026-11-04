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
| A crash | `echo "crash once" > <stub_dir>/runner` | The turn ends: `the agent crashed: :crashed`, and the next starts (`crash` makes every next turn crash too). |
| Another owner | `atlas set UC-Atlas-NN assigned_to=<another agent> --cause …` | The turn ends: `AS-UC-Atlas-NN is no longer runner's to work on`, and no new one starts. |
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

## IS-Atlas-18: Claude Code headless as a port

Runtime's second port, `claude`, runs one Claude Code process per turn, headless, confined to the `atlas` commands of the machine's own instance. The design part, with the first real turns: `~/agent-reports/atlas/2026-11-04-is-18-claude-port-design.md`.

- **The command:** `claude -p "<prompt>" --output-format stream-json --verbose --restricted --strict-mcp-config --tools Bash --allowedTools "Bash(atlas get:*)" "Bash(atlas list:*)" "Bash(atlas set:*)" --permission-mode dontAsk --no-session-persistence --model <model> --max-budget-usd <budget> --append-system-prompt "<rules>"`, with stdin from `/dev/null`.
- **Its folder:** a fresh one per turn, `turns_dir/<turn key>`. The raw stream is kept there in `stream.jsonl`.
- **Its environment:** cleared down to a few names (home, user, language), plus `ATLAS_AS=<agent>` and the instance's `ATLAS_ENV_FILE`. Its PATH holds two folders:
  - `bin`, with only a wrapper `atlas`: it refuses `--env`, another `ATLAS_ENV_FILE`, and any command but get, list and set;
  - `sys`, with only what Claude Code needs for itself: on macOS `security`, for its keychain login.
- **Its stream:** every line is activity for the lease. Exit 0 ends the turn with its result; any other exit is a crash. A stop sends SIGTERM, then SIGKILL after 5 s.
- **No default command:** nothing runs Claude Code unless an agent's settings name it.

```json
"runtime": {
  "machine": "macbook", "turns_dir": "…/turns",
  "agents": { "trial": { "port": "claude", "command": "…/claude", "model": "sonnet", "budget_usd": 0.5,
                          "silence_seconds": 120, "max_seconds": 300, "turn_limit": 1 } }
}
```

- **Repeated crashes**, read from the turns in State:
  - the next turn waits a pause that doubles with each crash in a row (`crash_pause_seconds`, 10);
  - after 3 crashes in 10 minutes on a machine, the agent gets no more turns there, and Runtime puts `cannot_run` on the agent ("on macbook since …: 3 crashes in 10 minutes"), cleared once that is no longer so.
- **`turn_limit`:** no more turns for that agent on that machine than that, ever. A trial's one.
- **Tests and CI** use a fake `claude` that prints the same stream. The e2e keeps the stub.

## IS-Atlas-92: the agent's own commands, with only `atlas` on their PATH

Claude Code's allowlist let `atlas set --help 2>&1 | head -50` run in IS-Atlas-18's second real turn, so the PATH is the guard that holds, and `sys` (`security`) was on it.

- **The shell prefix:** the turn's environment sets `CLAUDE_CODE_SHELL_PREFIX` to `turns_dir/<turn key>.shell`, beside the turn's folder, not in it. Claude Code runs each of the agent's Bash commands through it as `<prefix> '<its command string>'`.
- **What it does:** it keeps the command string in `turns_dir/<turn key>.commands`, sets PATH to the turn's `bin` alone, makes PATH readonly, and runs the command. PATH has to be readonly: Claude Code first sources its shell snapshot, whose last line sets PATH back to its own (with `sys`). The agent cannot widen PATH either (`PATH=/usr/bin:$PATH head …` fails).
- **Claude Code itself** keeps `bin` and `sys` on its own PATH, for its keychain login.
- **Not stopped by a PATH:** a full path such as `/usr/bin/head` still runs. Only Claude Code's permissions stand in its way there.
