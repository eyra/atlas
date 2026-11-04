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

Delivery remains the Bus's best effort contract: reads/facts retry and reconcile from
State. Machine leases and Flow failover across machines remain follow-up work; this
link does not end a sleeping machine's turns on another machine's behalf.

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0015).</sub>
