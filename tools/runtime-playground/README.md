# Private Runtime prototype

This directory retains two independent entry points. `run.py` is the standalone detached Runtime/Codex prototype documented first. The original stub-only `bin/atlas playground` / `bin/atlas attach --prototype` path is documented below. Use each launcher's own attach/probe/shutdown commands; their instance directories, worker identities and process manifests are not interchangeable.

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

The schema/typed codecs and attachment policy reuse upstream `181f3c3d528c7f46f7488c4d0ceb176c7c201154`, integrated without a baseline switch. The standalone entry point does not depend on `bin/atlas` or Console/TUI integration. Exact execution attachment is snapshot-only and requires a real turn/attempt pair; current legacy turns without an attempt are refused, never assigned a fabricated one. The worker-level viewer remains available for these turns. No guidance/output/replay capability is inferred from attachment.

The standalone launcher does not run or modify original playground instances or managed worktrees. Historical source informed the bootstrap pattern; the prototype runs entirely from this checkout.

## Prior verification

Actual fresh Rela/State/Flow/Runtime smoke proved: stopped boot; start; duplicate start; detach and fresh-terminal reattach to the same running turn; explicit reconnect; abrupt terminal loss and EOF without stopping the worker; stop and output inspection; invalid version/target and unfenced/stale execution refusals; a lost start reply followed by reconnect without command replay; explicit instance shutdown and child cleanup. Suspending the fresh Rela child produced a status error, then recovery without a Runtime restart. Terminating a separate fresh Rela closed its controller and produced bounded viewer disconnection. All smoke instances were closed.

Codex verification: an actual ChatGPT-authenticated Codex turn read the sample and completed with an explanation; a second running turn was explicitly stopped and recorded as stopped. Focused adapter/Runtime tests cover successful completion, missing completion, failure/nonzero exit, process-group stop and owner-loss cleanup. Tests use a fake executable and never call a model.

## Changes

2026-11-06: added the private single-worker command loop, isolated launcher, explicit lifecycle replies, non-fatal State status errors, and request-only status output.

2026-11-06: added the official Codex adapter, owned process-group runner, explicit `--agent codex` selection, per-start single-turn admission, final-answer inspection and lifecycle regression tests. Canonicalized private build paths to preserve Mix's `priv` symlink on macOS.

2026-11-06: separated supervisor and viewer lifetime; added attach/probe/shutdown, generated Runtime controls, bounded correlation/reconnect, exact execution policy, State failure recovery and owned-child shutdown. `quit` now detaches instead of stopping the private instance.

2026-11-06: retained both independent launcher paths during the develop merge, including original client/session regressions and launcher-specific shutdown documentation. No model run or integration proof was performed for this merge.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>

## Original stub-only playground · UC46 / IS125

The following commands and lifecycle details apply only to `launch.py` / `playground.exs`, reached through `bin/atlas`. They do not describe `run.py` or its Codex adapter above.

Private prototype depending on IS126 PR103, contract pin
`c34193806fdcceebbe47a00ba6d40ec158970077`. The local terminal client attaches to an
independent headless Runtime, with real Bus, State, Flow, leases and stored turn
history. The existing built-in agent stub is the only simulated component. There
is no model, guidance support, harness, external action or live environment data.

From this checkout, choose a fresh private directory (path at most 75 characters
for macOS Unix sockets):

```sh
bin/atlas playground init /tmp/my-runtime-playground
bin/atlas attach breaker --prototype /tmp/my-runtime-playground
```

The launcher uses an already cached pinned Rela binary; it never installs one.
Configuration copy requires the repository's Python dependencies. It compiles the
existing BEAM apps with one scheduler. Init creates only private synthetic facts
and leaves the worker stopped. The viewer itself starts no applications or agent.

At the prompt: `start`, `stop`, `status`, `mode active`, `mode idle`, `mode silent`,
`mode crash-once`, `mode crash`, `reconnect`, `detach`. These are generated typed
controls, never conversational guidance. Repeated start is idempotent. Attaching,
closing, detaching or reconnecting a viewer never starts/stops another worker.
Reconnect is bounded to five local attempts. The client checks outer, status and
execution worker identities against its selected environment/machine/worker before
displaying events or replies; optional error targets are checked when present.
Probe mode uses the same binding. Terminal result/error IDs are consumed once;
duplicate, unknown and late replies are rejected. At most eight requests may be
outstanding, with visible backpressure and ten-second expiry. Expiry or reconnect
leaves outstanding outcomes unknown; controls are never automatically replayed.
Status events neither complete requests nor extend their deadlines.

The line socket uses a 256 KiB buffer as well as a 256 KiB packet limit, so a
status containing accumulated turn history is decoded as one JSON frame. This
fixes fragmented status replies/events; it does not fix State timeouts or provide
controller recovery. A retained directory must not be passed to `init` again.

Private snapshot refreshes run every five seconds; explicit controls answer immediately.
Flow retains hints and a ten-second reconciliation fallback. Link origins use an
in-memory relation index rebuilt from the unchanged State ledger at startup, so
retained turn history does not cause one full-ledger scan per displayed turn.

Idle keeps renewing its lease; silence ends the turn after eight seconds; maximum
duration is 120 seconds. Runtime replaces eligible ended turns using its existing
behavior. Crash-once returns to active mode. Repeated crashes eventually trigger
Runtime's existing three-crash breaker; restarting the viewer does not reset that
durable history. Stop explicitly ends turns. Empty outcome means none was stored;
the displayed end reason is not a fabricated agent outcome.

This first UI exposes no handover stimulus or outcome-writing control. It displays
any actual handover state and retains the integrated IS123 sequencing behavior.
Remote discovery/transport, credentials, durable event replay, guidance and real
model trials belong to the separately planned issues. The prototype transport is
an owner-only local Unix socket; it is not a production remote endpoint. Its
directory is mode 0700 and socket mode 0600. Herdr only displays the terminal and
is not part of the product protocol.

IS139 adds an **explicit execution-bound, read-only profile** to this same private
controller/socket. After an operator explicitly starts the private worker, inspect
`bin/atlas playground probe DIR status`, then copy its actual running turn and
attempt (never invent one):

```sh
bin/atlas attach breaker --prototype DIR --turn TURN --attempt ATTEMPT
```

The shared DSL generates option parsing, codecs, validators and data types. The
shared client session lives in `clients/agent/lib/atlas_agent/runtime_session.ex`.
This profile offers `status`, `reconnect`, and `detach` only. Negotiated capabilities
are snapshot=true and control/guidance/output/replay=false. Events are current
State-derived turn snapshots, **not harness output or an IS110 replay cursor**.
Every result, error and event binds outer and nested worker/turn/attempt identities.
Repeated snapshot sequences are refused; reconnect resets snapshot sequencing and
reattaches the same execution with no outstanding control replay. When that
execution ends or disappears, its subscription closes with a typed stale-execution
event; no successor is selected. Separate viewers never start or stop workers.

This is the existing IS125 private controller, **not deployed Atlas Control**.
Owner-only directory/socket access is the prototype authority. The IS127 machine
registry read grant confers no worker attach/control permission and is not sent.
IS128 retains ordinary Control integration through IS109 and bounded output/cursors
through IS110; both services are currently unimplemented dependencies. No guidance
receipt pipeline, remote listener or output store is introduced here. The original
worker-only operator profile remains compatible. Frozen human instances are not
modified or upgraded by this source change.

Stop the complete private instance from another terminal:

```sh
bin/atlas playground stop /tmp/my-runtime-playground
```

The launcher retains OS argv and process-start identities in `processes.json` and
checks each retained PID's role, exact canonical instance arguments, executable,
owner and birth identity before signalling. Prefix collisions, PID reuse, missing
metadata and ambiguous/stale records refuse stop; it never discovers replacement
processes. This metadata is required for newly initialized instances. An older
frozen instance is not upgraded or retrofitted by this launcher.
Private Rela data, State ledger, `events.jsonl`, `server.log` and PID files stay in
that directory. No Fly tunnel, production/test environment file, shared service or
resource is touched. `probe DIR status` under `atlas playground` provides a typed
JSON result for inspection. Run the bounded private integration proof with
`python3 tools/runtime-playground/test_playground.py`; it is also in the e2e suite,
alongside mocked stop regressions, actual Client/probe peer fixtures and deterministic
session deadline/bound tests. The latter start no Runtime or worker.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0030).</sub>
