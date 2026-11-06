# A private Runtime node (IS-Atlas-91)

Runtime can run on a separate machine without Erlang distribution. Its Bus connects
through a private TCP link, forwarding envelopes and replaying endpoints and listeners
after reconnect. The node starts only Runtime and Bus. Every endpoint is named
`runtime@<machine>` or `runtime@<machine>/<turn>`; Control discovers machine endpoints
for failure actions. A core with no configured agents starts no Runtime engine.

The deployed test and prod settings intentionally have no `bus_link`. Activating the
listener on Fly, installing its secret, and running agents on the user's test data
require approval. No real model turns are part of this verification.

For an approved activation, the core settings gain (with no public Fly service):

```json
{"bus_link": {"host": "::", "port": 7694}}
```

The core secret `ATLAS_BUS_LINK_TOKEN` is a JSON object mapping machine names to distinct
random tokens. Binding the token to a machine prevents one admitted machine from
attaching another machine's endpoints. The local keychain item has service
`atlas-bus-link-test`, account `<machine>`, and that machine's token as its password.
Never put tokens in tracked settings. Test and prod use separate secrets and keychain
services. The wire is JSON lines over the encrypted `fly proxy` tunnel, not public TCP.

Create `~/.local/share/atlas/test-runtime/runtime.json` locally:

```json
{
  "env": "test",
  "bus_link": {"mode": "client", "host": "127.0.0.1", "port": 7695,
               "remote_port": 7694, "machine": "macbook"},
  "runtime": {"machine": "macbook", "agents": {"stand-in": {"port": "stub"}}}
}
```

`atlas runtime --env test` starts the tunnel and node in the background;
`atlas runtime-status --env test` reports its process and log;
`atlas runtime-stop --env test` stops that node and its tunnel. A started process can be
waiting to reconnect; consult its log and the turn's lease in Control for progress.
The token is removed from Runtime's process environment before agent ports start.
Agents' CLI calls still use the ordinary environment file and reach Control.

Private test instances use `ATLAS_RUNTIME_FILE` and `ATLAS_RUNTIME_HOME` pointing inside
their temporary directory, a loopback link, and an ephemeral `ATLAS_BUS_LINK_TOKEN` in
the launching environment. They need no keychain or Fly. The e2e runner uses this path:
UC-07's turns run in a separate OS process; restarting the core cuts the link and
registrations return. Restarting Runtime ends orphaned turns and starts new ones.

Readonly machine status (IS135): `atlas runtime status --env test
--machine macbook --json` inspects the selected local node. The existing
`runtime-status` alias derives an omitted machine from Runtime configuration.
Missing identity fails explicitly. The shared DSL generates options, machine DTO,
codecs and validators; exact worker identity remains separate.

Status creates no Runtime directories or bytecode cache, starts no service, opens
no Control/Bus/Fly connection and reads no keychain token. Shared contract codecs
must already be built; run `mix compile` in bff/contract as explicit setup. Missing
codecs fail visibly. JSON reports absent, stale, unverified or unsupported with
exact target, evidence basis and optional PID/log. A live legacy PID is unverified,
because PID existence cannot establish Runtime role/instance/start ownership or
health. Wrong environment/machine is explicit; no worker identity is invented.

Verified local lifecycle (IS136) uses `atlas runtime start|stop --env test
--machine macbook --json` through the same generated machine contract. Bare
`atlas runtime` remains the start alias; `runtime-stop` remains the stop alias.
These are explicit same-user local operations. Machine lifecycle never attaches a
viewer or selects a worker. Remote status remains unsupported; IS127 stays open
for authorized availability through existing Control. Self-reported client identity
does not grant remote access.

Start binds the canonical checkout, instance directory, configuration path,
environment, machine and fresh instance nonce in the Runtime boot arguments and
retained record. OS UID, process birth, exact role arguments and retained PID must
agree before a repeated start returns the existing node or stop sends SIGTERM.
Lifecycle requests serialize with an exclusive instance lock. PID-only legacy,
stale/reused, out-of-range, wrong-role and mismatched records refuse actions.
Stop never signals a process group or escalates to SIGKILL. Each exact process is
rechecked immediately before its individual signal; exit must be confirmed before
its PID record is removed. This is same-user OS process management, not an atomic
kernel identity-and-signal primitive or protection against a malicious same-user
process modifying records concurrently.

A startup receipt confirms that the existing IS91 node started Runtime and Bus
without State/Flow/Control. Owned process status does not assert Bus connectivity,
worker health or model readiness. A partial startup, unknown OS identity or
unconfirmed exit fails visibly and preserves records; there is no blind cleanup
or PID-only recovery. The lock is never cleared by guessing whether its PID is
alive. Inspect the retained evidence before manual recovery. Logs, configuration,
startup receipts and completed process birth records survive stop and restart;
a new start archives the prior stopped instance record.

Status still performs only reads. The local lifecycle capability flags describe
supported actions for the observed/configured instance, not credential or remote
availability. No credentials are probed by status. No listener, guidance pipeline
or model is added. Successful diagnostic exit means a report was produced, not
that Runtime is ready. Contract codecs must be built explicitly before any CLI
operation; start uses the existing Mix node boot, which can compile that checkout.

Delivery remains the Bus's best effort contract: reads/facts retry and reconcile from
State. Machine leases and Flow failover across machines remain follow-up work; this
link does not end a sleeping machine's turns on another machine's behalf.

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0015).</sub>

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0027).</sub>
