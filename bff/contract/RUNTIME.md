# Runtime contract

`AtlasBFFContract.Runtime` owns the shared data models and wire vocabulary. The
existing Blocks catalogue imports them so Control and terminal adapters can use
the same definitions. `Runtime.Protocol` generates request/result/event JSON
codecs, strict validators, dispatch and literal CLI bindings; `Runtime.Types`
generates the shared structs. The JSON file target exports the same definitions.

The first consumers are the private IS125 stub playground and later production
CLI/Console adapters. Declaring a command does not expose an endpoint or grant a
permission. Services still authenticate identities, authorize targets, report
proven capabilities, bind request IDs and enforce lifecycle policy. This slice
does not activate a worker, listener, model or harness.

Control frames use channel `control`, version `0.1.0` and a request ID. Status
events use channel `event` and a sequence; they are snapshots/hints, not durable
guidance receipts. All carry environment/machine/worker identity. Turn snapshots
carry the real turn identity; an attempt is optional for existing unfenced turns
and must never be fabricated. Harness capability absence means unproven; adapters
reuse the existing execution registration evidence, without a second pipeline.

Use strict `decode_request`, `decode_reply` and `decode_event` (or their JSON
variants) at new boundaries. Unknown versions, commands, fields and malformed
nested models return explicit invalid results. Existing `classify` retains its
legacy additive-reply behavior for current Control clients. Validation describes
shape; it does not establish authority or supported capability versions.

The literal CLI bindings generate controls, never prose prompts. Attachment is a
viewer operation; its adapter must not implicitly start or stop the worker.
Durable conversation remains on its existing guidance/evidence boundary. Ephemeral
output uses the separate profile below. Run `mix test` here for executable
compatibility fixtures; CI runs these with the generated-file check.

## Bounded ephemeral output

`Runtime.OutputProtocol` defines `runtime_output_snapshot` and
`runtime_output_read` on channel `runtime_output`, version `0.1.0`.
`Workers.Protocol` defines the Control-facing `worker_output_subscribe`,
`worker_output_next` and `worker_output_unsubscribe` operations. These are
demand-driven batches, not raw harness logs or terminal attachment.

Output requires the complete `runtime_execution`: environment, machine, worker,
turn and a real registered attempt. Legacy unfenced turns do not gain fabricated
output support. `worker_view.output` is independent of guidance availability;
an absent field does not establish support.

Every stream carries its execution, epoch, first retained sequence, snapshot
watermark and `ended` flag. **`ended` means producer closure, not authoritative
worker completion.** Current facts and outcome still come from `worker_view`.
Events carry their sequence and one closed projection: `text`/`activity` with
`text`, or `tool` with `tool_name` and `status`. Native records, reasoning, tool
arguments/results and environment are not output events. Diagnostic artifacts
remain separate and are not converted to durable conversation.

Snapshot atomically captures the watermark and a replay cursor preceding the
requested retained events. Later reads include post-snapshot appends without
requiring a viewer registration in the producer. A cursor is opaque and scoped
to the complete execution, epoch and sequence; it is never a State position.
Each viewer keeps its own last accepted cursor, discards duplicates and requests
replay on a sequence gap. Reconnect refreshes exact-target facts first, then
resumes ephemeral output independently of durable history.
New subscribers without a cursor also receive an explicit `retention_gap` when
the retained prefix starts after sequence one, with lost bounds
`1..first_sequence-1`; their replay cursor still precedes the first retained event.

Retention loss returns `reset.reason = retention_gap` with inclusive
`from_sequence`/`to_sequence`. A different epoch returns `epoch_changed` without
inventing an unknown loss range. Missing/expired rings return `output_unavailable`;
Control must pair that with an explicit reset and fresh authorized facts, not
invent an empty successful stream. Malformed, cross-target or future cursors are
`invalid_cursor`. A reset never silently selects a successor turn.

| Resource | Fixed production bound |
|---|---|
| Per stream | 1 MiB encoded events, 1000 events, 15-minute event age |
| Whole Runtime store | 64 streams, 16 MiB encoded events |
| Individual event | 16 KiB, with UTF-8-safe text chunking |
| Replay event array | 64 KiB |
| Control viewer pending output | 256 KiB maximum; one outstanding batch request |

The store evicts closed streams before the oldest-produced live streams under
aggregate pressure. Reads do not extend retention. Producer closure retains
bounded replay; timed cleanup removes closed rings and monitors. Store loss does
not end an eligible worker: its next producer event may reopen the same confirmed
execution with a fresh epoch. Viewer reads never open a ring, renew activity
leases, or stop a worker.

### Transport ownership and implementation boundary

`AtlasRuntime.OutputEndpoint` serves typed read requests at
`runtime@<machine>/output`, Bus class `request`, kind `runtime.output`; answers
preserve the request ID. It checks the Bus-stamped `control/*` sender,
environment, destination, execution machine and payload/envelope ID binding.
Only Control performs actor authorization and supplies authoritative State facts.

The Runtime producer/shared-contract slice does **not** implement the separately
owned addressed Bus request route, Control subscription lifecycle, or Console
consumer. Their declarations are not capability proof. Control must bound total
subscriptions and send/request deadlines as well as each viewer's pending bytes;
a slow viewer must reconcile explicitly without blocking Runtime or other viewers.
Private snapshot attachment and the standalone Runtime CLI remain unchanged.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
