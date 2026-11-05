# Runtime Playground · UC46 / IS125

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

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0027).</sub>
