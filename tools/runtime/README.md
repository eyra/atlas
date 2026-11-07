# Runtime service and CLI

One Go command-line client, a separate Elixir Runtime daemon, and explicitly targeted concurrent native workers. Each worker has at most one active execution. Codex remains the default without configured preferences; Claude requires explicit selection or an explicit preference. No Atlas server connection or orchestration. Runtime and Bus are the only Atlas applications started; State, Flow, Control and Rela are not started.

```sh
atlas-runtime service start
atlas-runtime start --cwd /path/to/project "Read the project and explain its entry points"
atlas-runtime status
atlas-runtime output
atlas-runtime stop
atlas-runtime service stop
```

Commands return one JSON response, except `output --follow`, which streams JSON lines. `start` returns while the selected native agent runs. `stop` stops only the selected worker's agent, not the service. `service stop` stops all workers and then the daemon; a partial stop failure retains completed stops and refuses shutdown. `service status` exposes a `workers` map. Single-worker `agent_state`/stop `agent` fields remain available only when unambiguous. No automatic daemon startup, assignment retries or stdin session. Command failures exit nonzero. A successful `status` or `output` query exits zero even for a failed turn, retaining its `state: "failed"`, `error`, ID and artifact location.

## Explicit concurrent workers

```sh
atlas-runtime start --worker server --backend claude --repo https://github.com/eyra/atlas.git --branch work/server-task --permissions dedicated-repository "Server assignment"
atlas-runtime start --worker console --backend claude --repo https://github.com/eyra/atlas.git --branch work/console-task --permissions dedicated-repository "Console assignment"
atlas-runtime start --worker runtime --backend claude --repo https://github.com/eyra/atlas.git --branch work/runtime-task --permissions dedicated-repository "Runtime assignment"
atlas-runtime status --worker server
atlas-runtime output --worker console --follow
atlas-runtime stop --worker runtime
atlas-runtime continue --worker server --turn turn-0123456789abcdef "Next server assignment"
```

Worker names match `[a-z][a-z0-9_-]{0,63}`. Flags precede the assignment; use `--` before a dash-leading assignment. Start/status/output/stop/continue accept `--worker`. Omission selects `default` when no workers are registered, or the sole registered worker; multiple workers always require a selector, even when only one is active. Workers register only after accepted start/continue and remain registered until daemon restart. Explicit unknown workers refuse except when starting or selecting a saved turn. A duplicate active worker refuses rather than queues.

`output --turn ID` and `continue --turn ID` resolve the saved worker. Supplying `--worker` as well must match; a session cannot transfer to another worker. Older saved turns without worker attribution belong to the original single-worker `default`. Restart clears the worker registry, starts no native processes and selects no historical execution automatically. `turns` lists all workers' history; `events` remains one global ordered stream, with `worker_id` on every new event. Older journal entries remain unchanged and unattributed. There is no per-worker cursor/filter or scheduler.

Real isolated public-CLI proof on 2026-11-07: Server `turn-849a0f44f47663c9`, Console `turn-711cf725b155be0f` and Runtime `turn-a7e5136ac3891023` each provisioned a separate clone/branch from base `568217bf7986b3f266be4df27fc121cb13200fb9`. All three real `claude-opus-5-5` sessions overlapped inside bounded Bash calls. Stopping Runtime removed its process group/private temp while Server and Console remained running, then independently finished with exact worker-specific file contents and answers. Events attributed accepted/finished/stopped transitions to the correct workers/turns. Ambiguous control, duplicate worker, workspace collision and mismatched saved ownership refused; repeated stop added no event.

After daemon restart, explicit Server continuation `turn-6f4aa53f92af74df` retained session `b400b621-68e0-488e-8d16-c95fec47e819`, model, cwd, repository and permissions, recalling the previous answer without tools. Targeted follow pinned worker/turn; replay from the prior global cursor returned only the continuation pair. The 39 focused ExUnit tests, 27 Python runner tests and Go CLI suite passed. All owned proof daemons/process groups/private temp directories were absent afterward; disposable binaries/builds were removed. That concurrent-worker proof did not exercise question/reply. Peer chat, scheduling, automatic recovery and Server/Console integration remain outside this capability.

## Durable execution discovery

```sh
atlas-runtime events --limit 50
atlas-runtime events --cursor "$NEXT_CURSOR" --limit 50
atlas-runtime output --turn turn-0123456789abcdef
```

`events` is a finite query, not a watcher. It returns immutable ordered lifecycle snapshots with stable turn IDs, worker attribution for new events, backend/native identity when known, and references usable by `output --turn` for status and logs. `execution_accepted` means Runtime accepted a start or continuation; `execution_finished` means the native turn ended normally, **not that its assigned task was verified successful**. Failure and explicit stop use `execution_failed` and `execution_stopped`. Assignments, answers and full logs are not copied into the event stream.

The response includes `events`, `next_cursor`, `has_more`, `earliest_cursor`, `retention_gap` and `recording_started_at`. Save `next_cursor` only after processing the returned page. It advances only through returned events; an empty page preserves the supplied cursor. The initial empty query still returns a usable cursor. Replaying a retained cursor returns the same ordered prefix; newly appended events may extend a previously short page.

Default page size is 50, maximum 100. The bounded journal retains the latest 256 events with bounded identity fields. Omitted cursor starts at the oldest retained event and reports `retention_gap` if earlier events were removed. Explicit stale, foreign, malformed and future cursors are refused; a stale-cursor error identifies the earliest usable cursor. Cursor identity and events survive clean daemon restart. Replacing/removing the journal starts a different stream, never silently reuses old cursors.

The journal begins when this capability is first started; `recording_started_at` marks coverage. Existing mutable turn files are not backfilled into invented historical acceptance/terminal events. Corrupt journals fail visibly rather than reset. This is not abrupt-crash recovery, automatic re-execution or verified-task reporting; existing output/history remain the detailed evidence.

Verification on 2026-11-07: eight focused journal tests and the Go CLI suite passed, including retention gaps, malformed/foreign/future/stale cursors, corrupt storage and a worst-case escaped 100-event response below the 1 MiB socket cap. Real isolated Claude turns `turn-c5719def1b653ee6` and `turn-75138de581f8e32f` produced accepted/finished sequences 1–4 with native session `da1e4115-ee6b-415b-8a47-a3f4fd5a40fe` and model `claude-opus-5-5`. One-event pagination, repeated-cursor replay, daemon restart from the prior cursor, empty checkpoint stability and historical output lookup passed. A separately labelled synthetic native executable exercised actual daemon failure/stop transitions, repeated-stop deduplication and post-restart stop replay; these are lifecycle checks, not provider-failure evidence. All owned proof daemons/process groups were stopped and build/fixture scaffolding removed.

## Continuing a conversation

After `status` reports `finished`, continue that Codex conversation:

```sh
atlas-runtime continue "Now explain the tradeoff in more detail"
```

`continue` starts a new Runtime turn for the selected worker using its previous explicit native `session_id`, working directory and sandbox. No setting overrides are accepted. Without a turn selector, that worker's current turn must be successfully finished. `start` always creates a fresh conversation. Native session confirmation is required; there is no `--last` selection or fallback to another session. Both native CLIs retain conversation history in their normal local storage; Runtime artifacts remain separate. Restart clears all current-turn views and never restores a conversation automatically.

To explicitly resume a saved successful conversation, including after daemon restart:

```sh
atlas-runtime continue --turn turn-0123456789abcdef "Next assignment"
```

The saved turn must be `finished`, with a native session ID and valid saved cwd/sandbox; its working directory must still exist. Failed, stopped, unknown and incomplete records are refused. An active agent for that worker blocks continuation; other workers may continue independently unless their workspaces overlap. A new Runtime turn/artifact folder is created; the selected record is unchanged. Selecting an older turn resumes that conversation's current native history, not a rollback or fork at the selected turn. If the selected native backend cannot resume the exact session, the new turn fails without fallback.

Codex defaults to **read-only**, using the official CLI and the user's existing ChatGPT login (`codex login`). Explicitly opt into Codex's workspace-write sandbox for an editing assignment:

```sh
atlas-runtime start --cwd /path/to/project --sandbox workspace-write "Make the requested file change"
```

The `--sandbox` option accepts only `read-only` and `workspace-write` for Codex. Status and output report the selected mode. A read-only denial never automatically escalates permissions. Both standalone backends reuse `AtlasRuntime.Agent.Native` and its owned process-group runner; no credentials are copied, no global native settings change, and no API fallback. Guidance, queues, multi-agent scheduling and Atlas hookup remain outside this step.

To explicitly select the installed official Claude CLI with its existing authentication:

```sh
atlas-runtime start --backend claude --cwd /path/to/project "Read the project and explain its entry points"
```

Claude defaults to fresh read-only file-tool assignments. Native restricted/safe modes expose only `Read`, `Glob` and `Grep`, confine those file tools to the working directory, disable user/project customizations and MCP servers, and deny permission prompts. This default is native tool-level restriction, not a claim of OS-wide sandbox confinement. No Bash, write, browser or network tool is enabled in read-only mode; normal provider communication and existing native authentication remain available. API-key/token environment overrides are not forwarded.

Claude generic workspace-write is explicitly refused before execution. Unknown backends are refused. Started turns never switch vendors or retry automatically. Saved legacy turns without a backend remain Codex turns; new turns persist `backend`, native `session_id` and native-confirmed `model` when available. Claude local errors with a synthetic assistant model do not replace the native initialization model. A pre-request failure can therefore identify the configured native model without claiming that model completed an inference. Codex model identity comes from this invocation's native session `turn_context`, matched by session ID, working directory and timestamp; unavailable evidence remains `null`, never copied from the requested model.

Claude requires native initialization identity, a successful result and clean process exit before Runtime reports completion. Native JSONL and final/error text remain inspectable through the same artifacts and output commands. Native Claude persistence is enabled for new turns. The Atlas-connected Claude adapter and broker are unchanged.

### Explicit Claude continuation

`continue --turn ID` resumes a successful Claude turn with official `--resume UUID`, the confirmed original model, cwd and permission scope. Native initialization must confirm the exact session and model; a different model in subsequent assistant output also fails. Missing model, session, saved execution context or native history fails visibly, without a new session or provider fallback. Earlier Claude turns created with persistence disabled cannot be recovered through this feature.

Each Claude execution records `claude-context.json` with canonical cwd, permission scope and Git root/branch/origin identity. Continuation revalidates that context before native execution; unreadable Git identity fails closed. Branch/origin drift refuses rather than switching/resetting. Detached HEAD identity is pinned to its revision and cannot continue after that revision changes. Managed continuation retains the existing origin/branch/ownership checks and preserves unfinished work without fetching or reprovisioning. Every write-scoped attempt receives a new owned private temp subtree with the existing byte limit and cleanup rules. Preference/model changes do not migrate saved conversations.

Real isolated restart proof on 2026-11-07: turns `turn-58f8fe115a937a1e` and `turn-1fe661d1abf893e3` retained native session `0e7c47b3-e8ec-40df-9abe-2ab169eadb1a` and actual model `claude-opus-5-5`. First turn remembered a unique conversation-only marker and made an uncommitted edit. After daemon restart and changing the preferred model to `claude-sonnet-4-6`, explicit saved continuation recalled that marker without repeating it in the assignment or reading files/logs, made a second edit and preserved the managed branch/base/scope. Each turn made one successful Bash call. Exact file bytes, missing-session/model/scope-drift admission refusals, private-temp removal and native process cleanup were checked. No automatic recovery, failed-turn retry, live input or worker push/PR was added.

## Opt-in Claude questions

```sh
atlas-runtime start --worker research --backend claude --questions --cwd /path/to/project "Ask which module to explain, then explain it"
atlas-runtime status --worker research
atlas-runtime answer --worker research --turn "$TURN_ID" --question "$QUESTION_ID" --answers '{"Which module?":"runtime"}'
```

Copy the exact question text and opaque question ID from `pending_question` in `status` or `output`. Every answer requires the current worker, Runtime turn and question ID; omitted selectors, wrong targets, duplicate/late answers, extra fields and permission updates refuse. Answers must cover the exact question-text key set with nonempty string values, including custom text. At most four questions, two to four options each, 4 KiB per question text/answer value, 32 KiB native question input and 16 KiB answer JSON are supported. Unsupported native question shapes fail closed rather than being silently changed.

Only explicit `start --questions` enables this path. `questions_enabled` is saved with the turn; continuation retains it and accepts no override. Legacy turns remain disabled. A selected Codex backend refuses the capability rather than changing provider. Default Claude execution remains `dontAsk`/`none`, with no live input.

The opt-in uses native stream input and `manual`/`host` permissions with the stdio permission host. It adds `AskUserQuestion` to available tools, not the automatic allowlist. The host approves only the exact pending question, bound to the owned process, native session/model, tool-use ID, process-local request ID and original input. Non-question permission requests are denied; mode/scope changes are refused. Existing read-only tool restrictions and repository Bash/private-temp sandbox settings remain. This shifts the question permission decision into Runtime; it is not a blanket equivalence claim between native permission modes.

`answer` reports `status: "delivered"` only after the native input write completes. `last_answer.status: "processed"` requires the matching non-error native tool result. Neither proves the model used the answer correctly or completed the assigned task. There is one bounded pending/in-flight answer, no durable answer recovery or exactly-once guarantee. Stop, completion, transport loss and failed delivery invalidate the pending question and clean up the owned process group. Historical records never expose a stale actionable question.

Real isolated public-CLI proof on 2026-11-07 with Claude 2.1.280 / `claude-opus-5-5`: read-only turn `turn-04a7f0a8940de9dd` asked, accepted a newly generated custom answer and returned `657050 + 37 = 657087` in the same execution. Write-scoped turn `turn-d4d47e2afce4f490` asked before any edit, then used one successful Bash call to write exactly `native-answer-d7a74a7277c4\n`; sibling and `.git/config` writes received `PermissionError` and preserved original bytes. Wrong worker/turn/question, mismatched answer keys and duplicate answers refused.

After daemon restart, continuation `turn-9dc6eb32607cfb71` retained the original session/model and opt-in, asked a fresh question, then stopped while pending; a late answer refused. All three native process groups, the write-scoped private temp and both isolated daemons were absent afterward. Focused checks passed: 49 ExUnit tests, 45 Python runner tests and the Go CLI suite. Run both Python modules with `python3 -m unittest beam/apps/atlas_runtime/test/codex_runner_test.py beam/apps/atlas_runtime/test/claude_question_runner_test.py`. No default installation, Atlas integration or comprehensive native-version/network certification was performed.

Claude's documented [`[1m]` context-window option](https://code.claude.com/docs/en/model-config.md) can remain in native initialization (`claude-opus-5-5[1m]`) while assistant records name its base model (`claude-opus-5-5`). Question-host and continuation checks accept only that exact base-model representation difference, not arbitrary aliases, other modifiers or different models. Initialization/session and resumed configuration checks remain exact. Runtime retains the initialized `[1m]` value for status and saved continuation rather than silently replacing its context option with the assistant's base ID. Native artifacts preserve both original representations.

Default-selection regression proof on 2026-11-07: retained failed turn `turn-70c8440cf908d6d6` and daemon diagnostics established the assistant identity comparison as the cause. Fixed isolated public turn `turn-2cc4a66a4f6196c3` used the same cwd and command semantics, no model preference or `--model` override, and exposed a pending question held for two seconds. Fresh answer `768259` produced correlated processing and result `768276` (+17). After daemon restart, continuation `turn-e61d8bbff3826258` retained session `c48f2e47-c72c-4daa-9adf-c657724c5c82` and configured model `claude-opus-5-5[1m]`, returning `768278` (+19) from prior conversation context. Both streams retained init `[1m]` and assistant base IDs. Focused verification passed: 41 ExUnit and 46 Python tests, including the failing-before question regression and strict mismatch cases. Owned native groups/daemons were absent afterward; disposable client/build removed. Default installation and daemon were untouched.

## Claude scoped repository writes

Select Claude repository writes explicitly with `atlas-runtime start --backend claude --cwd /canonical/independent/repository --permissions dedicated-repository "Edit the assigned file and create a local commit"`, or use managed `--repo` provisioning below. This reuses independent-root validation and owned directory locking. It enables Bash alongside read-only Read/Glob/Grep, never Edit/Write. Native settings require sandbox availability, disable unsandboxed escape and excluded commands, retain the existing GitHub domain list, and deny writes to `.agents`, `.codex`, `.aws`, `.claude`, `.git/config` and `.git/hooks`. Generic workspace-write remains refused.

The write scope is the assigned repository **plus one exact private native temporary subtree**, not repository-only and not identical to Codex confinement. Runtime securely creates an unpredictable `0700` `.ac-*` directory beneath the canonical user home for each execution. `process.json` records `native_temporary` and the exact native settings. Runtime removes only that owned directory after terminating the native process group, including failure/cancellation paths. System temporary roots remain write-denied; repositories inside those roots are unsupported. No shared `/tmp/claude-<uid>`, whole-home allowance or nested Codex wrapper is used.

Installed Claude Code 2.1.280 selects shared `/tmp/claude-<uid>` when the UTF-8 byte length of `<CLAUDE_CODE_TMPDIR>/claude-<uid>` exceeds 44. Its shell wrapper uses that selection for cwd bookkeeping and shell temporary files; setting launch `TMPDIR` cannot override it. Runtime validates this limit before spawning and fails explicitly on homes too long to fit. Earlier repository-local-temp attempts failed first on heredoc creation, then on wrapper cwd bookkeeping after a successful edit/commit. The short private directory fixes both in the bounded native proof below; arbitrary shell compatibility is not claimed. The [native sandbox documentation](https://code.claude.com/docs/en/sandboxing) describes shell-only isolation; built-in Edit/Write tools run outside it and remain disabled here.

Focused checks passed: 24 Python runner tests, including exact temp scope, the 44-byte boundary, long-home refusal, and cleanup on completion, native failure and stop. Earlier candidate verification also passed 26 Elixir policy/adapter tests and the Go CLI suite. Synthetic lifecycle checks do not substitute for native containment evidence.

Real public-CLI proof on 2026-11-07: turn `turn-b894577aa26ff18b`, native Claude `claude-opus-5-5`, session `5cb705a0-b34e-4eca-84fd-d7e881696841`. Exactly one Bash call ran ordinary shell output and a Python heredoc, edited `proof.txt`, and created local commit `160c948d5d973e89ca2bae17ffb01001a8f1d844` containing only that file with bytes `after-native-claude\n`. Bash succeeded without a tool error; native execution completed cleanly. Actual writes to an outside sibling, `.agents/protected.txt`, `.git/config`, and a separate owned sentinel outside the temp subtree were refused with original bytes preserved. Independent inspection confirmed the exact commit, scope, absent native process group and removed owned temp.

The proof used isolated Runtime state, after the trusted weekly reset; no default install, daemon restart, merge or deployment occurred. Push/PR operations from Claude, provisioning, continuation, comprehensive network isolation and arbitrary shell commands were not verified by this proof. Native source/version changes can alter temp routing and require new verification.

## Local backend preference

Configure the supported Claude-then-Codex pair for future assignments, optionally selecting native models:

```sh
atlas-runtime preferences --preferred claude --preferred-model 'claude-opus-5-5[1m]' --fallback codex --fallback-model gpt-6.1-sol
atlas-runtime preferences
atlas-runtime start --cwd /path/to/project "Read the project"
atlas-runtime preferences --reenable claude
```

Omit either model flag to use that CLI's native default. Model availability remains the native provider's decision; an unavailable model fails without retry. `preferences` reports configuration, retained quota evidence and current `claude_eligible`. Configuration and evidence persist atomically in `backends.json` beneath the selected Runtime home and survive daemon restarts. Invalid persisted policy fails visibly instead of silently selecting another backend.

Only a structured native Claude `rate_limit_event` with rejected `seven_day`, no active overage and no allowed overage can make Claude ineligible. The quota record retains native evidence, source turn ID, observation time and explicit re-enablement time. Generic authentication/network/provider errors, text mentioning limits and other quota windows do not change eligibility. A positive numeric native `resetsAt` restores eligibility at that Unix timestamp; missing/invalid reset evidence remains `null` and requires explicit re-enablement. Localized text such as “1pm” is never parsed. Re-enablement retains evidence; a later confirmed weekly rejection disables eligibility again.

An eligible preference selects Claude. Confirmed weekly unavailability selects Codex only for a subsequent explicit `start`; the failed Claude turn remains failed and is never replayed. `start --backend claude` or `--backend codex` bypasses eligibility selection, using the configured model for that backend when present, and never falls back. An incapable selected backend is refused before execution, without weakening permissions or marking capability errors as quota. For example, an eligible Claude preference cannot accept a workspace-write assignment; explicitly select Codex instead.

Turn metadata separates `requested_model` from native-confirmed `model`. `selection` records `requested`, `selected`, `reason` (`default`, `preferred`, `explicit`, `confirmed_weekly_quota` or `continuation`) and the source quota record when applicable. Continuation retains its saved provider and model regardless of changed preferences or quota eligibility; Claude requires a confirmed model rather than falling back to a requested alias. No scheduler, queue, automatic assignment or generic provider registry is introduced.

## Codex dedicated repository permissions

For an explicitly authorized Git/PR assignment in an **independent clone**, opt into a separate, fixed permission profile:

```sh
atlas-runtime start --cwd /canonical/path/to/independent-clone --permissions dedicated-repository "Complete the assigned change and create its PR"
```

This cannot be combined with `--sandbox`. It permits writes only beneath the canonical repository root, including its own `.git`, while retaining read-only `.agents`, `.codex` and `.aws` paths. Outside writes, including system temporary directories and home caches, remain denied; tools needing writable caches must use repository-local paths. Existing read access is unchanged. Command networking uses Codex's enforced proxy and allows only `github.com` and `api.github.com`; no unrestricted network fallback is provided.

Validation refuses linked worktrees, non-root/aliased paths, external/shared Git metadata, object alternates, metadata symlinks and shared hardlinks. Project/ancestor and system Codex configuration files are refused because legacy sandbox settings can override a native profile; the ignored user config is exempt. Use an independent remote clone, not a local clone with shared objects. Validation runs before launch and again before native execution.

The status/history `permissions` object records profile name/version, canonical root, Git directory and exact allowed network hosts; `sandbox` is `null` for this opt-in. Both ordinary and saved-turn continuation retain and revalidate that scope. There is no permission override on continuation and no fallback to a legacy mode. Native execution retains ignored user config/execpolicy rules, disabled hooks, no approvals, exact session confirmation and owned-process cleanup. The native profile path does not pass the conflicting `--sandbox` flag.

Use HTTPS Git transport with the existing GitHub CLI authentication when the stored origin uses SSH. For example, `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' -c remote.origin.url=https://github.com/eyra/atlas.git fetch origin develop`. Apply the same per-command URL/helper settings to push; do not change global Git configuration or copy credentials. `gh pr create --repo eyra/atlas ...` uses the same allowed GitHub API host. Domain approval does not restrict access to one GitHub repository: the authenticated account's GitHub rights still apply.

Verified on macOS with Codex 0.166.0. Other platforms/versions are not certified. Native network denial can terminate the entire shell command; it is not necessarily a catchable HTTP error inside a script.

## Managed repository provisioning

Both explicit `--backend claude` and eligible preferred-Claude selection support this existing provisioning path. Git preparation still uses the installed Codex sandbox and its fixed repository profile, without making a Codex model request. Missing Codex fails explicitly rather than running unsandboxed Git. Once preparation and scope validation succeed, Claude executes in its own native repository-plus-private-temp scope; there is no nested Codex wrapper around Claude. Existing clone identity, clean-worktree, branch-existence and ownership checks apply unchanged. Explicit successful-session continuation preserves unfinished work.

Verified through an isolated public CLI on 2026-11-07: eligible preferred Claude provisioned `https://github.com/eyra/atlas.git` on `work/runtime-claude-managed-proof` at freshly fetched base `c59b1971b323f1242fb372a1a4ebe926f7db4167`. Turn `turn-2a5912b14bd3f675`, native `claude-opus-5-5`, session `e29bd430-e7e0-4ac2-b79b-613fe864b517`, made one successful Bash call and local commit `5501bcf876a65e4a3c5b79ddd049c468754d8bc1`. Its parent matched recorded base and `origin/develop`; its only changed file contained `native Claude managed provisioning proof\n`. Repository remained clean, private temp and native process group were absent afterward, and the isolated service was stopped. No worker push/PR, live Atlas call or default-instance change occurred. Focused verification passed 25 Python runner/provisioning tests and 26 Elixir policy/native-adapter tests.

To have Runtime provision the clone and task branch, supply an explicit GitHub HTTPS URL and a new branch instead of `--cwd`:

```sh
atlas-runtime start --repo https://github.com/eyra/atlas.git --branch work/server-task --permissions dedicated-repository "Complete the assigned change"
```

The daemon manages one independent clone per worker and normalized owner/repository beneath its selected state directory: `workers/<worker>/repositories/<owner>/<repository>`. Each caller supplies its own task branch. Older managed paths remain available to their saved continuations; new starts use worker-specific paths without moving existing work. The URL must name `https://github.com/OWNER/REPO[.git]`, without embedded credentials, query strings or fragments. `--repo` and `--branch` must be supplied together with explicit dedicated-repository permissions, and cannot be combined with `--cwd` or `--sandbox`. Repository choice, branch name and assignment remain external decisions.

Runtime clones an absent path or reuses only a matching Runtime-marked independent clone with a matching origin and clean tracked/untracked state. It freshly fetches remote heads, records the exact `origin/develop` commit, and creates the requested new branch at that commit. Existing local or remote task branches are refused, including `develop`. Dirty, unmanaged, mismatched or actively owned paths are refused without reset, stash, deletion or branch overwrite; ignored-file collisions also prevent checkout. Previous task branches/commits stay intact. Stale remote-tracking branches are not automatically pruned.

Git preparation runs under the same native repository/network profile, using the existing GitHub credential helper without copying credentials or changing global Git config. The existing runner holds an advisory directory lock through preparation, native execution and process-group cleanup. Dedicated-repository starts, and legacy `--cwd` starts on a marked managed clone, honor that lock. The daemon also refuses canonical identical, nested or parent workspace overlap with any active worker, including symlink aliases and unscoped sandbox modes. Directory locks coordinate Runtime owners; they are not locks against humans or other tools that ignore them.

`start` still returns before completion: a running turn is not proof that preparation or native execution succeeded. On preparation success, the stream includes `runtime.repository_prepared`, and status/history persist `repository: {url, branch, base_sha}` before the worker starts. Preparation refusals leave a failed turn with diagnostics in its `stderr.log`; partially prepared paths are preserved for explicit inspection, never automatically deleted or retried.

Saved/ordinary continuation reuses the exact session and scope without fetching, recreating a branch or discarding unfinished work. Managed continuation additionally requires the saved origin and branch to still match. If another task reused the clone and switched its branch, continuation refuses rather than switching it back. No automatic scheduling, recovery, installation, merging or deployment is introduced.

The client talks to an owner-only Unix socket under `~/.local/state/atlas-runtime/`. `service.log` contains daemon diagnostics. Per-turn artifacts retain full native JSONL, stderr, final answer and process details. `output` returns the selected worker's final answer and a bounded 64 KiB native event tail. Restart resets the in-memory worker registry; retained artifacts do not trigger restoration or re-execution.

Watch a worker's current turn with `atlas-runtime output --worker NAME --follow`, or omit the worker only when unambiguous. The client resolves and pins worker/turn identity once, reads that turn's local `stream.jsonl` from the beginning and polls targeted status every 200 ms. Output is newline-delimited JSON: initial `{"type":"status","turn":...}`, native `{"type":"event","worker_id":...,"turn_id":...,"event":...}` records, then `{"type":"result","turn":...}` with terminal status and answer. Completed turns replay and exit; idle returns one result immediately. Native events are emitted once per invocation, including events larger than the ordinary output tail. Incomplete records wait for completion; malformed/truncated final JSON fails rather than disappearing.

Ctrl-C stops the viewer, not the agent. Another `start`/`continue` replacing the selected turn causes a command error rather than silently following another assignment; service loss also fails visibly. Failed/stopped terminal results remain successful inspection commands (exit zero), not proof of assignment success. This is native event output, not a guarantee of token-by-token text streaming.

Inspect local turn history through the running daemon:

```sh
atlas-runtime turns
atlas-runtime output --turn turn-0123456789abcdef
```

`turns` returns a `turns` array, newest start first, with worker IDs, assignments, states, settings, native session IDs and timestamps. Each new turn saves `turn.json` atomically beside its existing artifacts at start, native session confirmation, and terminal transition. `output --turn ID` returns the selected turn's answer and bounded native event tail without changing any worker's current turn. Unknown/malformed IDs fail; historical failed/stopped turns remain inspectable with exit zero. Explicit historical selection is a snapshot command, not combined with `--follow`.

History survives daemon restart, but `status` still starts idle and plain `continue` does not select saved history. Only explicit `continue --turn ID` selects a saved successful conversation. Older artifact folders without metadata remain readable with state `unknown`; missing assignment/timestamp/session fields are not guessed. A saved `running` turn no longer owned by this daemon is shown as `unknown` with `recorded_state: running`, not claimed to be active or successful. No automatic restart, crash recovery, retention/deletion policy or server connection is introduced.

Requires the normal Elixir/OTP/Mix toolchain, Python 3 and the selected official CLI (`codex` or `claude`) on PATH. First service start compiles Runtime and Bus into its own build directory. `ATLAS_RUNTIME_HOME=/absolute/path` selects an isolated instance; use it consistently across commands. Directory aliases are resolved before building, including macOS `/tmp` → `/private/tmp`, so Mix's relative `priv` links resolve to the actual runner.

## Install

From the Atlas checkout, with Go installed:

```sh
go build -ldflags "-X main.repoRoot=$PWD" -o "$HOME/.local/bin/atlas-runtime" tools/runtime/main.go
```

The binary points to this checkout for service startup; rebuild if the checkout moves. Restart an existing daemon after updating the service/adapter code so it loads the new version (stopping the service also stops any active agent). The service is not implemented in Go and does not live inside the client process. Existing Atlas-connected launcher tooling is left untouched.

## Model-free native sandbox verification

On macOS with Seatbelt, Python 3 and the official Codex CLI installed, run from `beam/apps/atlas_runtime`:

```sh
MIX_ENV=test mix run --no-start ../../../tools/runtime/verify_sandbox.exs
```

This opt-in check requires no login or model call and starts no Runtime daemon or Atlas core applications. It uses isolated workspaces and empty Codex homes, then removes its own temporary files. The Runtime adapter and process runner launch a small protocol bridge that reads the actual forwarded `--sandbox` and `--cd` arguments. The bridge maps the two supported modes to Codex's documented [built-in permission profiles](https://developers.openai.com/codex/permissions), `:read-only` and `:workspace`, and invokes the official `codex sandbox` command to execute the same bounded shell write. The bridge reports the native exit status and stderr; it does not simulate denial or perform the write itself.

Assertions require read-only to produce an actual `Operation not permitted` shell error, exit 1 and unchanged `before\n` bytes; workspace-write must exit 0 and produce exact `after\n` bytes. A wrong forwarded mode changes the native outcome and fails the check. CLI configuration/usage errors cannot pass as a read-only denial. Codex 0.166.0 was exercised; older CLIs lacking these built-in profiles will fail this explicit check rather than silently skip it.

Boundary: this proves native sandbox enforcement and adapter-to-native mode selection through the bridge, not model-driven `codex exec` scheduling or its internal legacy-flag-to-profile conversion. It does not test broader filesystem/network confinement or other platforms. No production policy or adapter implementation is changed.

## Verified

Explicit Claude selection was exercised through an isolated public Runtime CLI with Claude Code 2.1.280. Native initialization confirmed only `Glob`, `Grep`, `Read`, no MCP servers, `dontAsk`, and model `claude-opus-5-5[1m]`. The single attempt was rejected by the existing weekly limit: `rateLimitType: seven_day`, `overageDisabledReason: out_of_credits`, zero input/output tokens. Runtime retained the model/session and exact error answer, marked the turn failed, refused continuation, and cleaned the native process group. No retry or fallback was attempted. A successful real Claude read remains unverified because of this quota limit; deterministic native-stream regressions cover successful completion, identity requirements, error precedence and private-content filtering.

Preference/fallback verification used clearly labelled synthetic replay of that exact previously observed weekly-quota event, not another Claude provider call. After an isolated daemon restart, a new public CLI assignment selected real Codex `gpt-6.1-sol`, returned `FALLBACK_OK`, and recorded native-confirmed model identity plus the quota selection reason. After explicit Claude re-enablement, Codex continuation kept the same session/model and returned `CONTINUATION_OK`. Public CLI/daemon checks also proved re-enablement persistence, generic-error non-poisoning, explicit backend override and incapable-backend refusal. Successful real Claude completion remains unverified; no additional Claude quota was consumed.


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

2026-11-06: closed the native write-denial evidence gap with the model-free verification above: 2 checks passed against official Codex 0.166.0, with real shell stderr/exit and exact on-disk bytes for both modes. The existing Codex adapter suite also passed all 9 tests.

2026-11-06: fixed a macOS cleanup exit race. Signalling an owned group whose last member is exiting/unreaped can return EPERM before a nonblocking poll can reap the leader. The runner now waits up to its existing three-second cleanup bound for that owned leader and retries the same group signal once, preserving descendant cleanup. A live leader beyond the bound or a second permission denial still fails; permission errors are not ignored. This preserves the original protocol/session failure rather than replacing it with cleanup EPERM. Focused checks from `beam/apps/atlas_runtime`: `python3 -B test/codex_runner_test.py -v` (3 real-process regressions) and `mix test test/codex_test.exs` (9 adapter tests), all passed. Direct runner smoke confirmed clean normal completion and explicit cancellation, with recorded native/sleep PIDs absent and empty helper stderr.

2026-11-06: added two cleanup safety-boundary checks without changing production code. With owned real processes and explicitly injected `killpg` permission failures, a live leader produces a bounded visible failure rather than hanging, and persistent denial still propagates after the exited leader is reaped. Existing exited-leader/live-descendant and original-session-error coverage is reused, not duplicated. `python3 -B test/codex_runner_test.py -v` now passes all 5 checks. These injected-denial results establish error propagation, not native foreign-user permission behavior or cross-platform proof.

2026-11-07: added explicit persisted dedicated-repository permissions. Disposable native Runtime proof created a branch/commit, denied outside/protected writes, fetched authenticated GitHub develop, accessed the repository API, and denied a nonapproved domain. Saved-turn continuation after daemon restart retained the same native session and exact scope; altered saved scope and worktree admission were refused. Eight Python regressions, ten Codex adapter tests, Go client tests and both model-free legacy sandbox checks passed. Default installed daemon and binary were not changed.

2026-11-07: added explicit managed repository provisioning through `start --repo ... --branch ... --permissions dedicated-repository`. An isolated Runtime cloned Atlas, fetched fresh develop, recorded its exact base, and ran a real native worker that created and committed one proof file. CLI checks preserved work while refusing existing branches, dirty state, mismatched origin and active ownership; clean reuse preserved the previous task commit. Saved continuation after restart retained native session/repository context and unfinished work, while older branch context was refused. Cancellation reaped the owned group and released repository ownership. Fourteen Python regressions, ten adapter tests, Go client checks and both native legacy-mode checks passed. Default installed Runtime was not changed.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
