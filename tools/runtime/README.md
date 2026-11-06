# Runtime service and CLI

One Go command-line client, a separate Elixir Runtime daemon, and one Codex agent at a time. No Atlas server connection or orchestration. Runtime and Bus are the only Atlas applications started; State, Flow, Control and Rela are not started.

```sh
atlas-runtime service start
atlas-runtime start --cwd /path/to/project "Read the project and explain its entry points"
atlas-runtime status
atlas-runtime output
atlas-runtime stop
atlas-runtime service stop
```

Commands return one JSON response, except `output --follow`, which streams JSON lines. `start` returns while Codex runs. `stop` stops the agent, not the service. `service stop` stops both. `service status` checks the daemon. No automatic daemon startup, assignment retries or stdin session. Command failures exit nonzero. A successful `status` or `output` query exits zero even for a failed turn, retaining its `state: "failed"`, `error`, ID and artifact location.

After `status` reports `finished`, continue that Codex conversation:

```sh
atlas-runtime continue "Now explain the tradeoff in more detail"
```

`continue` starts a new Runtime turn using the previous explicit native `session_id`, working directory and sandbox. No setting overrides are accepted. Without a selector, the current turn must be successfully finished. `start` always creates a fresh conversation. Native session confirmation is required; there is no `--last` selection or fallback to another session. Codex retains its native conversation history in its normal storage; Runtime artifacts remain separate. Restart clears the current-turn view and never restores a conversation automatically.

To explicitly resume a saved successful conversation, including after daemon restart:

```sh
atlas-runtime continue --turn turn-0123456789abcdef "Next assignment"
```

The saved turn must be `finished`, with a native session ID and valid saved cwd/sandbox; its working directory must still exist. Failed, stopped, unknown and incomplete records are refused. Any active agent blocks continuation, even when selecting another turn. A new Runtime turn/artifact folder is created; the selected record is unchanged. Selecting an older turn resumes that conversation's current native history, not a rollback or fork at the selected turn. If Codex cannot resume the exact native session, the new turn fails without fallback.

Codex defaults to **read-only**, using the official CLI and the user's existing ChatGPT login (`codex login`). Explicitly opt into Codex's workspace-write sandbox for an editing assignment:

```sh
atlas-runtime start --cwd /path/to/project --sandbox workspace-write "Make the requested file change"
```

Only `read-only` and `workspace-write` are accepted. Status and output report the selected mode. A read-only denial never automatically escalates permissions. The Runtime reuses `AtlasRuntime.Agent.Codex` and its owned process-group runner; no credentials are copied, no global Codex settings change, and no API fallback. Guidance, queues, multi-agent scheduling and Atlas hookup remain outside this step.

The client talks to an owner-only Unix socket under `~/.local/state/atlas-runtime/`. `service.log` contains daemon diagnostics. Per-turn artifacts retain full native JSONL, stderr, final answer and process details. `output` returns the final answer and a bounded 64 KiB native event tail. Restart resets the in-memory current-turn view to idle; retained artifacts do not trigger restoration or re-execution.

Watch the current turn with `atlas-runtime output --follow`. The Go client reads that turn's local `stream.jsonl` from the beginning and polls status over the existing socket every 200 ms; no daemon changes or restart are needed for this feature. Output is newline-delimited JSON: initial `{"type":"status","turn":...}`, native `{"type":"event","turn_id":...,"event":...}` records, then `{"type":"result","turn":...}` with terminal status and answer. Completed turns replay and exit; idle returns one result immediately. Native events are emitted once per invocation, including events larger than the ordinary output tail. Incomplete records wait for completion; malformed/truncated final JSON fails rather than disappearing.

Ctrl-C stops the viewer, not the agent. Another `start`/`continue` replacing the selected turn causes a command error rather than silently following another assignment; service loss also fails visibly. Failed/stopped terminal results remain successful inspection commands (exit zero), not proof of assignment success. This is native event output, not a guarantee of token-by-token text streaming.

Inspect local turn history through the running daemon:

```sh
atlas-runtime turns
atlas-runtime output --turn turn-0123456789abcdef
```

`turns` returns a `turns` array, newest start first, with assignments, states, settings, native session IDs and timestamps. Each new turn saves `turn.json` atomically beside its existing artifacts at start, native session confirmation, and terminal transition. `output --turn ID` returns the selected turn's answer and bounded native event tail without changing the current turn. Unknown/malformed IDs fail; historical failed/stopped turns remain inspectable with exit zero. Explicit historical selection is a snapshot command, not combined with `--follow`.

History survives daemon restart, but `status` still starts idle and plain `continue` does not select saved history. Only explicit `continue --turn ID` selects a saved successful conversation. Older artifact folders without metadata remain readable with state `unknown`; missing assignment/timestamp/session fields are not guessed. A saved `running` turn no longer owned by this daemon is shown as `unknown` with `recorded_state: running`, not claimed to be active or successful. No automatic restart, crash recovery, retention/deletion policy or server connection is introduced.

Requires the normal Elixir/OTP/Mix toolchain, Python 3 and Codex on PATH. First service start compiles Runtime and Bus into its own build directory. `ATLAS_RUNTIME_HOME=/absolute/path` selects an isolated instance; use it consistently across commands. Directory aliases are resolved before building, including macOS `/tmp` → `/private/tmp`, so Mix's relative `priv` links resolve to the actual runner.

## Install

From the Atlas checkout, with Go installed:

```sh
go build -ldflags "-X main.repoRoot=$PWD" -o "$HOME/.local/bin/atlas-runtime" tools/runtime/main.go
```

The binary points to this checkout for service startup; rebuild if the checkout moves. Restart an existing daemon after updating the service/adapter code so it loads the new version (stopping the service also stops any active agent). The service is not implemented in Go and does not live inside the client process. Existing Atlas-connected launcher tooling is left untouched.

## Verified

Installed CLI exercised against a separate real daemon: idempotent service start, real Codex completion reading a disposable file, concurrent-start refusal, output retrieval, explicit real Codex stop with native-process cleanup, daemon survival after agent stop, service stop/restart, and refusal without implicit startup when the service is stopped. A synthetic hanging executable also proved daemon shutdown cleans its active agent process group. All smoke daemons were stopped.

2026-11-06: added the standalone Runtime service and Go client; kept Atlas orchestration out of this first interaction.

2026-11-06: fixed aliased build directories and separated command-error replies from failed-turn data. Reverified the reported `/tmp` instance with a real Codex assignment, then proved synthetic failure inspection exits zero while a refused command still exits nonzero. Response regression: `go test tools/runtime/main.go tools/runtime/main_test.go`.

2026-11-06: added explicit `--sandbox workspace-write`, retaining read-only defaults. Real Codex proof: default mode denied a write and left the file unchanged; opted-in mode changed exactly the requested file bytes; cancellation in write mode removed the recorded native, helper and sleep processes while leaving the daemon running. Unsupported sandbox admission and existing lifecycle regressions pass.

2026-11-06 release review: normal completion now terminates remaining descendants in the owned process group, including children that redirected their output. A synthetic regression reproduced the leak before the fix and passed afterward; no model invocation was needed.

2026-11-06: added explicit post-success `continue` with fixed cwd/sandbox. Installed CLI retained a marker across two real turns with the same native session ID and distinct Runtime IDs. Go response tests and all nine Codex adapter tests passed, including rejection of missing/mismatched resume confirmation.

Independent installed-CLI continuation verification passed: retained context, explicit-session resume, fixed cwd/sandbox, exact workspace-write bytes, CLI/socket override rejection, refusal while idle/running/stopped/failed, fresh-session starts, restart-to-idle, and cancellation of the recorded helper/native/descendant processes while the daemon survived. Both isolated daemons were stopped. The tester's separate read-only denial probe had only agent-prose evidence, not a captured command denial; no stronger confinement claim is made.

2026-11-06: added client-only `output --follow`. Real Codex smoke observed events while running and exactly matched all seven saved native events, ending with the expected final answer; idle returned immediately. Go regressions cover split UTF-8 records across EOF, a final record without newline, no duplicate emission, and truncated final JSON rejection.

Independent follow verification passed against the installed client and real daemon with deterministic native fixtures: live/replayed event equality, a 70,088-byte record, split UTF-8 across file growth, failed/stopped result inspection, viewer-only SIGINT, explicit agent stop, turn-replacement refusal, and visible service-loss errors. All owned followers and daemon processes were stopped. These fixture checks complement the real Codex smoke; they do not claim token-level streaming or abrupt-crash recovery.

2026-11-06: added persisted local turn history and explicit historical output. Installed real-Codex smoke ran an initial turn and continuation, inspected the first without replacing the second, restarted the isolated daemon, and recovered both finished turns in newest-first order with their shared native session, separate timestamps and correct answers. Current status remained idle; malformed turn ID was refused. Existing Go client regressions passed.

Independent installed-client/real-daemon history checks passed with deterministic native fixtures: finished/failed/stopped persistence, active-turn read isolation, graceful shutdown persistence, restart-to-idle, malformed/traversal ID rejection, legacy/stale-running unknown states, and a complete 1,207,791-byte history response. Ordinary individual output retains its pre-existing 1 MiB response cap. All owned test processes were stopped; abrupt-crash recovery was not claimed.

2026-11-06: added explicit saved-turn continuation. Real Codex smoke selected an older successful conversation after a newer unrelated session and daemon restart; the new turn retained the older marker, native session, cwd and sandbox. Plain continuation from idle still refused; selected history remained unchanged. Go client regressions passed; all owned smoke processes stopped.

Independent saved-resume verification passed: real Codex workspace-write after restart from a different client cwd, unchanged selected metadata, subsequent ordinary continuation, and 25 admission refusals without launching/replacing a turn. Deterministic native fixtures proved unavailable/mismatched session attempts fail without alternate-session launch, plus active-turn rejection and cancellation cleanup. Both isolated daemons were stopped; provider-side session deletion and abrupt-crash recovery were not tested.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
