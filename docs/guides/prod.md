# Atlas prod

Prod holds the plan: real scenes, use cases and issues. Its data is real from the first write: never wipe it, and never run the end-to-end test or an experiment against it. Try things in test (`atlas tui --env test`) or on a private instance (`ATLAS_ENV_FILE`).

Prod runs on Fly (IS-Atlas-79, below), like test since IS-Atlas-26 (`docs/guides/test-on-fly.md`). This Mac runs only its clients: the TUI, the agents' command line and the agent behind `:`.

## Start

```sh
atlas
```

The same as `atlas tui --env prod`. It opens the tunnel to prod's Control on Fly in the background (`fly proxy 7593:7591 -a eyra-atlas`, flyctl's WireGuard; flyctl must be logged in to organisation eyra), then a TUI. The header says `Atlas · prod` in white on red; test's header says `Atlas · test`, plain.

More:
- `atlas status`: the tunnel, and both apps' machines, checks and deployed build (the image label `master-<commit>`).
- `atlas logs`: the core's log on Fly; rela's is `fly logs -a eyra-atlas-rela`.
- `atlas stop`, `atlas restart`: close or reopen this Mac's tunnel; prod keeps running on Fly.
- `atlas env`: which environment a command works on.

**Prod runs master's build.** A merge to master deploys it (d-0014). A merge to develop changes this Mac's clients (the main clone follows develop) but not prod's core, so a new feature reaches prod only with the next merge to master. Control lets a client newer than itself in, and sends an older one away.

A deploy first checks that the build's description describes all of prod's data on Fly, as `atlas restart` did on this Mac (IS-Atlas-73). When it does not, nothing is deployed, prod keeps its build, and the job names the data: migrate it first (`docs/guides/test-on-fly.md`, "A migration").

## Where it runs

| | Test | Prod |
|---|---|---|
| rela | `eyra-atlas-test-rela` on Fly, private network only | `eyra-atlas-rela` on Fly, private network only |
| Control | `eyra-atlas-test` on Fly; this Mac's tunnel end 127.0.0.1:7693 | `eyra-atlas` on Fly; this Mac's tunnel end 127.0.0.1:7593 |
| Data | the apps' volumes on Fly | the apps' volumes on Fly (the Mac's copy from before the move: `~/.local/share/atlas/prod/`) |

Both run the same pinned rela (26.10.14); test runs develop's newest build, prod master's. Test and prod never connect: each has its own Bus, and a prod Bus or Control refuses a test message or client (and the other way round). Facts never move from test to prod.

## Prod on Fly (IS-Atlas-79)

Prod gets the same two apps as test, on a private network of its own (`eyra-atlas-prod`), which test's apps and the rest of organisation eyra cannot reach. No public address.

| | App | Machine | Data |
|---|---|---|---|
| Core | `eyra-atlas` | shared-cpu-1x, 256 MB, ams | volume `core_data` at `/data` (State's own: `/data/beam`) |
| rela | `eyra-atlas-rela` | shared-cpu-1x, 256 MB, ams | volume `rela_data` at `/data` (`/data/rela`) |

A merge to master deploys prod (CI job `deploy-prod`, `fly/deploy.sh prod`). It works as test's:
1. The description check on rela's machine; nothing is deployed when the data does not fit.
2. rela, then the core.
3. The smoke check, which reads only.

`env/prod.json` names the apps in its `"fly"` section. Until the switch below it said `"in_use": false`: `atlas` kept using this Mac's prod core and rela, and only `atlas move-to-fly --env prod` and `atlas fetch-from-fly --env prod` went to Fly.

### Secrets

| Where | Secret | What | On this Mac today |
|---|---|---|---|
| eyra/atlas, repository secret | `FLY_API_TOKEN_PROD` | `fly tokens create deploy -a eyra-atlas` | (none: deploys are new) |
| eyra/atlas, repository secret | `FLY_API_TOKEN_PROD_RELA` | `fly tokens create deploy -a eyra-atlas-rela` | (none) |
| Fly app `eyra-atlas`, `fly secrets set -a eyra-atlas GITHUB_TOKEN=…` | `GITHUB_TOKEN` | the GitHub connector's token: reads the pull requests of eyra/atlas (private), GET only | `gh auth token`: `connectors.github.token_command` in `env/prod.json`, so Melle's own gh login (account mellelieuwes, keyring) |

On Fly the connector reads its token from that secret (`connectors.github.token_env` in `fly/prod/core.json`). A token that can only read pull requests of eyra/atlas is enough, for example a fine-grained token with "Pull requests: read" on that one repository. Until it is set, each round logs `no token: GITHUB_TOKEN is not set` and keeps the stored values.

There is no Flux connector yet: `flux_id` and `flux_ref` are described as set by a connector, but no code reads Flux, so nothing needs a Flux secret. When one is built, its secret goes on `eyra-atlas` the same way.

### Move prod's data, and switch (IS-Atlas-90)

Prod's data is real. Its move is checked item by item, and the Mac's prod keeps its data until the check passes. These steps run before the switch pull request is merged, while `env/prod.json` still says `"in_use": false`.

0. **Prod on Fly runs the build the Mac's prod runs.** The move checks the data against this build's description, and Fly's rela checks it again at boot against its own. Merge develop into master first; `deploy-prod` then deploys that build, and `atlas status` (`fly status -a eyra-atlas`) shows `master-<commit>`.
1. **Stop writes on the Mac and back up.** Stop the Mac's prod core and rela, so nothing changes after the copy (`atlas stop`, then `atlas rela-stop`). Then copy the folder: `cp -Rp ~/.local/share/atlas/prod ~/.local/share/atlas/prod-backup-$(date -u +%Y%m%dT%H%M%SZ)`.
2. **Dry run:**
   ```sh
   atlas move-to-fly --env prod --from ~/.local/share/atlas/prod-backup-<time> --dry-run
   ```
   It checks that this build's description describes all of that data. It counts the items per kind (`assignments` among them) and the links per relation (`links assignment` and `links accepted_by` among them).
3. **The move:** the same without `--dry-run`. It checks every file of `rela/` and `beam/` on Fly against what it sent, by SHA-256: every item, every Assignment, every link (accepted_by too), and State's own record of who set each link. Then it compares the counts. What Fly held before stays in `/data/before-move/`.
4. **Check through Control on Fly:** `fly/smoke.sh prod` counts every kind as Control on Fly reads it.
5. **Switch prod's clients** with the switch pull request (IS-Atlas-90): `env/prod.json` gets `"fly": {"in_use": true}` and `"control": {"port": 7593}`, the tunnel's end on this Mac, and loses the Mac-only settings (`rela`, `state`, `connectors`). From then on `atlas` opens the tunnel to `eyra-atlas` like `atlas tui --env test` does.
6. **If anything is wrong before the switch:** `atlas restart` starts the Mac's prod again on its own data, which nothing changed. After the switch, going back is reverting that pull request, then `atlas restart`: the Mac's prod data is still the one from before the move.

After the switch, keep `~/.local/share/atlas/prod` and the backup as they are. `atlas fetch-from-fly --env prod --to <folder>` makes a fresh backup from Fly at any time (about a minute in which prod serves nothing). A migration on prod runs as on test: `docs/guides/test-on-fly.md`, "A migration".
