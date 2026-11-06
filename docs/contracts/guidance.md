# Durable guidance foundation (IS-Atlas-105)

The selected description maps execution, interaction and receipt roles to kinds and
properties. Foundation supplies the three immutable entities. No Eyra work kinds
appear in the BEAM protocol; existing turn/Assignment links resolve the work item.

All writes travel over Bus to State, using an operation and semantic values.
Execution registration requires the durable running turn, worker, machine and
attempt. Only the owning Runtime machine or exact turn endpoint may register it
or publish receipts. The Bus link binds remote machine identity. Fenced turn
machine/attempt fields cannot be replaced through generic State writes. A failed
turn read refuses before ordinary storage. Only confirmed absence permits new turn
creation; successfully read unfenced turns retain compatibility. IS-108 introduces
their Runtime fences.

Confirmed absence alone does not authorize deleting a turn. State retains deletion
provenance in its private ledger: the full effective request (environment, Bus
sender, kind, payload) and the authorized machine/attempt/version. After ordinary
validation, this intent is synced immediately before the backend delete. Stored
acknowledgement and completion evidence are recorded together. Exact retries recover
the original acknowledgement/position after confirmed absence; a fresh envelope for
the same proven request can acknowledge absence without another backend mutation.
A crash after backend commit but before acknowledgement is recovered from the
synced intent. Unavailable/failed reads still refuse before any cached answer.
Changed sender/target/payload cannot borrow an old request id or deletion proof;
a reappearing target or replacement attempt cannot receive an old deletion. Old
unbound ledger entries are not guessed into authority. An already answered but
unbound id conflicts before either a present-target cache lookup or an absent-target
proof can bind it, including ordinary acknowledgements created by the current State.
The original answer stays unchanged and no deletion binding is added. Only an unused
id or an exact bound deletion request can enter those recovery paths.
This adds private ledger
keys, not schema entities or a data conversion.

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

Interaction create/replay/exact reads return immutable identity, a bounded projection
and receipt_count, never an embedded evidence history. Read the receipt role with
interaction=<key> and optional after_position/limit to traverse retained evidence.
Interaction pages select execution=<key>. Both collections are ordered by durable
State position, at most 100 records and 64 KiB of encoded JSON payload per page;
after_position/more continue after the last included record. Byte limits can make a
page shorter than its requested record count. The whole retained history stays
immutable; no evidence is purged or truncated to satisfy response limits.

Stored execution/receipt records are limited to 8 KiB each; interaction records to
32 KiB, measured as encoded JSON including server metadata and identity (both
semantic and mapped forms). Oversized writes refuse with record_too_large before
backend creation. Identical retries retain the original metadata: growth in the
newly reserved position cannot invalidate an already admitted boundary record.
Exact record reads enforce those bounds too. An out-of-contract
oversized retained record fails visibly rather than returning a non-advancing empty
page or silently discarding its contents. Summary projections retain only bounded
proof/uncertainty/closure state, regardless of evidence count. Control supplies
opaque client cursors later.

The current backend still scans collections internally; indexed storage can replace
that through State/Rela. Response bounds are not an indexed-query guarantee. All
receipts remain durable history, separate from future bounded token output.

The schema adds three kinds and optional turn attempt. Tests preserve every previous
definition and field order. No migration is required; closure/provenance packaging
includes the additions. Tests use private synthetic disk stores and pinned HTTP rela,
concurrent barriers and a deterministic loss after storage/before response. No models
or production data participate. Client Send and harness admission remain disabled
until IS-106–109 provide and prove their contracts.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0024).</sub>
