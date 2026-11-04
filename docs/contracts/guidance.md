# Durable guidance foundation (IS-Atlas-105)

The selected description maps execution, interaction and receipt roles to kinds and
properties. Foundation supplies the three immutable entities. No Eyra work kinds
appear in the BEAM protocol; existing turn/Assignment links resolve the work item.

All writes travel over Bus to State, using an operation and semantic values.
Execution registration requires the durable running turn, worker, machine and
attempt. Only the owning Runtime machine or exact turn endpoint may register it
or publish receipts. The Bus link binds remote machine identity. Fenced turn
machine/attempt fields cannot be replaced through generic State writes. Existing
unfenced turns remain compatible; IS-108 introduces their Runtime fences.

Interaction submission also carries by, asserted by an admitted Control session.
State refuses injected actor/environment/timestamp/position values. This retains
the existing admitted-client identity model. Local BEAM applications are trusted.
Control derives the client actor and checks current eligibility in IS-109.

State refuses ordinary CRUD on these roles. Identity scopes are:
- execution: environment, turn, attempt;
- interaction: environment, actor, client key;
- receipt: environment, interaction, evidence ID.

Atomic backend create claims the identity. On an existing key State compares the
complete immutable payload, including body bytes, target, mode and cause. Identical
replay returns the original record and current receipts; changed payload conflicts.
A new client key deliberately makes another interaction. No expiry or purge exists.

State reserves durable ordering before storage and persists the position with each
record. Gaps are allowed. A lost storage response cannot change its creation position.
Writer and payload checks precede every reply, bypassing the envelope answer cache.

Queued requires the stored interaction and a capable execution descriptor. Delivered
requires an admission ID; acknowledged requires admission and consumption IDs. Other
receipt stages require reasons. Runtime obtains these proofs from the adapter in
IS-108; output and socket writes prove neither. Canonical receipt writer is the
owning Runtime machine, allowing recovery from its exact turn or reconciler endpoint.

Projection preserves proven queued/delivered/acknowledged stage, independent
uncertainty and stale/unsupported/rejected closures. Late evidence never regresses
proof. Contradictory admission identities flag uncertainty. Uncertainty is conservative
and remains in history after proof improves. Historical evidence stays on its
original attempt; receipts change no ownership, leases, outcomes or acceptance.
Live eligibility and admission versus closure remain later Control/Runtime work.

Reads support exact identity and bounded execution history pages (maximum 100),
ordered by durable State position. after_position and more provide continuation;
Control supplies opaque client cursors later. The current backend scans collections
internally. Indexed storage can replace that through State/Rela. Retained receipt
evidence is durable history, separate from future bounded token output.

The schema adds three kinds and optional turn attempt. Tests preserve every previous
definition and field order. No migration is required; closure/provenance packaging
includes the additions. Tests use private synthetic disk stores and pinned HTTP rela,
concurrent barriers and a deterministic loss after storage/before response. No models
or production data participate. Client Send and harness admission remain disabled
until IS-106–109 provide and prove their contracts.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0024).</sub>
