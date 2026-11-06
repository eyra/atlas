# Private Runtime prototype

One worker with an independent local Runtime and detachable terminal viewers. Uses the existing Atlas Bus, real Rela-backed State, Flow, Runtime engine and turn supervisor. The default `stub` is synthetic; explicitly selecting `codex` enables a real subscription-backed Codex worker.

## Run

From the Atlas checkout:

```sh
python3 tools/runtime-playground/run.py
```

Requires the normal Elixir/OTP toolchain, configuration-copy Python dependencies (`.venv-config` when present), and the already cached `~/.local/share/atlas/test/bin/rela-server`. Nothing is downloaded. The launcher creates a fresh owner-only temporary directory, prints its location, copies the Rela description and compiles into that directory. It removes inherited `ATLAS_*` settings and uses Mix's isolated test boot configuration; it never loads production/test environment files or opens Fly tunnels.

Optionally choose a new short directory with `--directory /tmp/my-runtime-prototype`. Existing directories are refused, including the old playground's data. Data remains on disk after shutdown; a stopped instance is not restarted from its saved directory. `--background` creates the stopped Runtime without opening a viewer.

### Attach, detach and shut down

The launcher prints the actual directory. Substitute it for `DIR`:

```sh
python3 tools/runtime-playground/run.py --attach DIR
python3 tools/runtime-playground/run.py --probe DIR status
python3 tools/runtime-playground/run.py --shutdown DIR
```

`detach`, `quit`, EOF and closing/killing the terminal leave the Runtime alone. Reopen a terminal with `--attach DIR`, or type `reconnect` in an existing viewer. **`stop` stops the worker; `--shutdown DIR` stops the worker and the private Runtime/Rela processes.** The launcher confirms cleanup separately from the shutdown acknowledgement.

Viewer connections use the existing generated Runtime protocol over an owner-only Unix socket. Request IDs, deadlines and identity binding come from `AtlasAgent.RuntimeSession`; at most eight requests are outstanding. Reconnection has five connection attempts, discards pending reply expectations, and never replays lifecycle commands. If the reply to `start` is lost, inspect `status` rather than blindly resubmitting it.

### Run one real Codex goal

Requires Codex CLI 0.166.0-compatible flags, Python 3, and an existing ChatGPT login (`codex login`). The Runtime does not read or copy credentials.

```sh
python3 tools/runtime-playground/run.py --agent codex
```

This creates a disposable workspace containing `sample.py`. The goal is: “Read the sample project and explain what it does. Do not change files.” Override the text with `--goal "..."`; the workspace remains the disposable sample.

Nothing starts until you type `start`. Use `status` to follow activity and `output` for the final answer. Each explicit Codex start permits one turn only. A completed/failed turn does not automatically launch another; a new `start` deliberately runs the goal again. Repeated `start` while active returns the existing turn.

Codex runs through official `exec --json`, with read-only sandboxing, no approvals, ignored user config/rules and disabled hooks for this bounded prototype. The child environment retains only basic OS variables and `CODEX_HOME`, not API credentials; `forced_login_method="chatgpt"` selects the existing subscription login. This is not a general-purpose hostile-code sandbox or a change to the user's Codex settings.

Each turn retains `stream.jsonl`, `stderr.log`, `answer.txt` when written, and process identity in `turns/<turn>/`. The adapter requires both `turn.completed` and exit 0 before reporting successful completion. A clean exit without completion, a failure event or a nonzero exit is a failure. Stop sends SIGINT to the owned process group, escalates after three seconds, and waits for process termination before Runtime records the stop. Losing the owning turn also requests cleanup. Live guidance and session resumption are not supported by this adapter.

Codex's prototype silence limit is 120 seconds and maximum turn length is 300 seconds. Startup reports a running Runtime turn, not that the provider has already accepted the prompt. An authentication failure appears through the turn failure and retained diagnostics.

At the prompt:

```text
list
status
start
status
stop
status
quit
```

- `list`: show the selected private environment/machine/worker identity.
- `status`: show the engine, adapter mode and stored turn identities, states, activities and leases. Viewer snapshots arrive every five seconds; there is no full-history snapshot file.
- `start`: enable the existing Runtime engine and observe the new turn; a very fast completed turn is reported as ended rather than falsely timing out.
- `output`: read the latest Codex final answer from local turn artifacts; explicitly reports when no final answer exists. This is not a new output-stream wire protocol.
- `stop`: disable the engine, ask every local turn to end and wait for no local or stored running turn. Repeated stop is safe. The recorded end reason is `explicit private operator stop`.
- `reconnect`: reconnect to the same worker without starting or stopping it.
- `detach` / `quit` / EOF: close this viewer only.

`--probe DIR COMMAND` emits a generated JSON reply and exits nonzero for a refused command. Interactive viewers render concise snapshots and explicit errors. A State read timeout returns `State status unavailable`; after State recovers, status works again. Lifecycle transitions have a 10-second observation deadline (an in-flight State read can add its existing six-second retry window); an unconfirmed transition is reported as unknown and is never automatically replayed.

The stub produces activity under the existing turn lease mechanism. A turn's maximum is 120 seconds; the existing Runtime engine may start a successor while enabled. `stop` disables that continuation. State's genuine lifecycle/lease ledger remains durable and is not truncated.

## Boundary

The Python supervisor owns only the Rela/controller processes it created; external shutdown uses the private socket, never signals stale PID files. If Rela exits, the supervisor closes and reaps its controller rather than restarting it. An unavailable/closed instance cannot be resurrected by attaching. There is no OS-login service, cross-machine endpoint, worker migration or reboot recovery. Private socket access is local owner authority, not a Control grant.

The schema/typed codecs and attachment policy reuse upstream `181f3c3d528c7f46f7488c4d0ceb176c7c201154`, integrated without a baseline switch. No `bin/atlas` or Console/TUI changes. Exact execution attachment is snapshot-only and requires a real turn/attempt pair; current legacy turns without an attempt are refused, never assigned a fabricated one. The worker-level viewer remains available for these turns. No guidance/output/replay capability is inferred from attachment.

The old playground and managed worktrees are not run or modified. Historical source informed the bootstrap pattern; the prototype runs entirely from this checkout.

## Verification

Actual fresh Rela/State/Flow/Runtime smoke proved: stopped boot; start; duplicate start; detach and fresh-terminal reattach to the same running turn; explicit reconnect; abrupt terminal loss and EOF without stopping the worker; stop and output inspection; invalid version/target and unfenced/stale execution refusals; a lost start reply followed by reconnect without command replay; explicit instance shutdown and child cleanup. Suspending the fresh Rela child produced a status error, then recovery without a Runtime restart. Terminating a separate fresh Rela closed its controller and produced bounded viewer disconnection. All smoke instances were closed.

Codex verification: an actual ChatGPT-authenticated Codex turn read the sample and completed with an explanation; a second running turn was explicitly stopped and recorded as stopped. Focused adapter/Runtime tests cover successful completion, missing completion, failure/nonzero exit, process-group stop and owner-loss cleanup. Tests use a fake executable and never call a model.

## Changes

2026-11-06: added the private single-worker command loop, isolated launcher, explicit lifecycle replies, non-fatal State status errors, and request-only status output.

2026-11-06: added the official Codex adapter, owned process-group runner, explicit `--agent codex` selection, per-start single-turn admission, final-answer inspection and lifecycle regression tests. Canonicalized private build paths to preserve Mix's `priv` symlink on macOS.

2026-11-06: separated supervisor and viewer lifetime; added attach/probe/shutdown, generated Runtime controls, bounded correlation/reconnect, exact execution policy, State failure recovery and owned-child shutdown. `quit` now detaches instead of stopping the private instance.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
