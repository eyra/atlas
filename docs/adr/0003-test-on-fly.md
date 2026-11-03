# 0003: Test on Fly: two apps on test's own private network

Status: accepted, 2026-11-03 (Melle: "i think we just need to create a new fly eyra-atlas-test", "and eyra-atlas (the prod)"; d-0005, d-0014). IS-Atlas-26; prod follows the same way in IS-Atlas-79.

## Context

Test ran on the MacBook: rela on 7690 and the core (Bus, State, Flow, Control) on 7691, started by `atlas up --env test`. d-0005 puts rela on Fly, reachable only over a private network; d-0014 deploys test on every merge to develop. Runtime and the agents stay on the MacBook (d-0006), and they and the TUI are clients of Control.

## Decision

1. **Two apps: `eyra-atlas-test` (the core) and `eyra-atlas-test-rela` (rela)**, each one machine (shared-cpu-1x, 256 MB, region ams) with its own 1 GB volume at `/data`.
   - rela is an outside system to State, the same pinned binary as on a Mac (`rela/scripts/start-test.sh`). As its own app it keeps its own lifecycle: a core deploy restarts the core only, while rela keeps serving.
   - A crash of one does not take the other down, and its logs, checks and status are its own (`fly status -a …`).
   - Each has its own deploy token, so CI's core token cannot touch rela's data except through Control.
   - Cost: one more machine and volume of the smallest size, and a deploy of two apps in order (rela, then the core).
2. **Test's own private network.** Both apps were created with `--network eyra-atlas-test`, a Fly network of their own: the other apps of organisation eyra (eyra-flux*, eyra-next*, nova-mica*) cannot reach them, and prod gets its own network (d-0003: test and prod never connect). No app has a public address or a `[[services]]` section; `eyra-atlas-test.fly.dev` resolves to nothing.
3. **The MacBook reaches Control over WireGuard with `fly proxy`.** `bin/atlas` opens `fly proxy 7693:7691 -a eyra-atlas-test` in the background when a command needs Control, like it starts the core on a Mac. flyctl's own WireGuard tunnel joins test's network without root, a system VPN or `.internal` DNS on the Mac. The TUI and the agents' command line keep talking to `127.0.0.1`; they do not know test moved.
4. **CI deploys on a merge to develop** (`.github/workflows/ci.yml`, job `deploy-test`), after every other job passed: rela, then the core, each image labelled `develop-<commit>`, then `fly/smoke.sh test`, which reads only.
5. **Data moves with `atlas move-to-fly --env test`**: the Mac's rela and State folders, as archives, applied at boot by `fly/apply-move.sh` while nothing serves them; what was on Fly is kept in `/data/before-move/`.

## Consequences

- `atlas up/stop/restart --env test` no longer run a core on the Mac; `atlas status --env test` shows Fly's machines, `atlas logs --env test` Fly's logs. A private instance (`ATLAS_ENV_FILE` without a `fly` section, as the end-to-end test makes) still runs on the Mac.
- The migrations (`atlas migrate-*`) read rela on the Mac and are refused for test; a future migration on Fly runs through Control or inside the rela machine.
- Every client on a machine needs flyctl logged in to organisation eyra (the Mac mini too, when it runs test's agents).
