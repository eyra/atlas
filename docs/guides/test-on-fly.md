# Atlas test on Fly

Test's core (Bus, State, Flow, Control) and its rela run on Fly, in organisation eyra, on test's own private network; nothing of it has a public address. Runtime and the agents stay on the MacBook. Why two apps and how they connect: `docs/adr/0003-test-on-fly.md` (IS-Atlas-26).

| | App | Machine | Data |
|---|---|---|---|
| Core | `eyra-atlas-test` | shared-cpu-1x, 256 MB, ams | volume `core_data` at `/data` (State's own: `/data/beam`) |
| rela | `eyra-atlas-test-rela` | shared-cpu-1x, 256 MB, ams | volume `rela_data` at `/data` (`/data/rela`) |

## Use it

```sh
atlas tui --env test        # opens the tunnel to test's Control on Fly, then the TUI
atlas list scene --env test # the agents' commands too; each opens the tunnel when it is closed
atlas status --env test     # the tunnel, and both apps' machines, checks and deployed build
atlas logs --env test       # the core's log on Fly (rela's: fly logs -a eyra-atlas-test-rela)
atlas stop --env test       # closes this Mac's tunnel; test keeps running on Fly
```

The tunnel is `fly proxy 7693:7691 -a eyra-atlas-test`, flyctl's WireGuard into test's network, running in the background like the core used to. It needs flyctl logged in to organisation eyra (`fly auth whoami`); nothing else on the Mac (no VPN, no root). Its files are in `~/.local/share/atlas/test-on-fly/`.

`atlas up --env test` is gone: a merge to develop deploys test (CI job `deploy-test`), rela first, then the core, then a smoke check that reads only (`fly/smoke.sh test`). `atlas status --env test` shows the build as the image label `develop-<commit>`.

## The secrets CI needs

Two repository secrets, one deploy token per app (each can manage only its own app):

```sh
fly tokens create deploy -a eyra-atlas-test -n "eyra/atlas CI"        # secret FLY_API_TOKEN_TEST
fly tokens create deploy -a eyra-atlas-test-rela -n "eyra/atlas CI"   # secret FLY_API_TOKEN_TEST_RELA
```

Until both are there, the deploy job fails on its first step and names the missing one.

## Move test's data from the MacBook

The MacBook's test data (`~/.local/share/atlas/test/`: `rela/` and State's `beam/`) stays where it is after the merge; nothing reads or stops it. To take it to Fly:

1. Stop the Mac's old test core and rela, so the copy is whole:
   ```sh
   kill "$(cat ~/.local/share/atlas/test/core.pid)"
   ATLAS_TEST_ROOT=~/.local/share/atlas/test ~/projects/eyra/atlas/rela/scripts/stop.sh
   ```
2. Back it up: `cp -Rp ~/.local/share/atlas/test ~/.local/share/atlas/test-backup-$(date +%F)`.
3. See what would happen; nothing is sent:
   ```sh
   atlas move-to-fly --env test --from ~/.local/share/atlas/test-backup-<date> --dry-run
   ```
   It checks that this build's description describes all of that data, counts the items per kind, and shows what Fly holds now.
4. Move it: the same without `--dry-run`. It sends both folders, restarts rela and then the core on Fly (the copy is put in place at boot, before anything serves it), and compares the counts per kind on Fly with the ones it sent. What Fly held before stays there, in `/data/before-move/` on both apps.
5. `atlas tui --env test` shows the moved data.

Without `--from` it moves `~/.local/share/atlas/test` itself, and refuses while a rela still serves it.

## When something is wrong

- `atlas status --env test`: a machine not `started`, or a check not passing.
- `atlas logs --env test`, `fly logs -a eyra-atlas-test-rela`.
- rela does not start when this build's description no longer describes data it holds (as on a Mac, IS-Atlas-73): its log names that data, the deploy fails, rela stays down until that data is migrated, and the core stays on the build before.
- `fly ssh console -a eyra-atlas-test-rela` opens a shell on rela's machine; its data is in `/data/rela`.
