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

Every command exits with one JSON response. `start` returns while Codex runs. `stop` stops the agent, not the service. `service stop` stops both. `service status` checks the daemon. No automatic daemon startup, assignment retries or stdin session. Command failures exit nonzero. A successful `status` or `output` query exits zero even for a failed turn, retaining its `state: "failed"`, `error`, ID and artifact location.

Codex defaults to **read-only**, using the official CLI and the user's existing ChatGPT login (`codex login`). Explicitly opt into Codex's workspace-write sandbox for an editing assignment:

```sh
atlas-runtime start --cwd /path/to/project --sandbox workspace-write "Make the requested file change"
```

Only `read-only` and `workspace-write` are accepted. Status and output report the selected mode. A read-only denial never automatically escalates permissions. The Runtime reuses `AtlasRuntime.Agent.Codex` and its owned process-group runner; no credentials are copied, no global Codex settings change, and no API fallback. Guidance, queues, multi-agent scheduling and Atlas hookup remain outside this step.

The client talks to an owner-only Unix socket under `~/.local/state/atlas-runtime/`. `service.log` contains daemon diagnostics. Per-turn artifacts retain full native JSONL, stderr, final answer and process details. `output` returns the final answer and a bounded 64 KiB native event tail. Restart resets the in-memory current-turn view to idle; retained artifacts do not trigger restoration or re-execution.

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

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
