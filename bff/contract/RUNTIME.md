# Runtime contract, first slice

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
Conversation, harness output and external Rela/Claude protocols remain their
existing adapter boundaries. Run `mix test` here for executable compatibility
fixtures; CI runs these with the generated-file check.

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0027).</sub>
