# Atlas prod

Prod holds the plan: real scenes, use cases and issues. Its data is real from the first write: never wipe it, and never run the end-to-end test or an experiment against it. Try things in test (`atlas tui --env test`) or on a private instance (`ATLAS_ENV_FILE`).

For now prod runs on this MacBook, until it moves to Fly as test did (IS-Atlas-79; that move takes the data along). Test runs on Fly since IS-Atlas-26: `docs/guides/test-on-fly.md`.

## Start

```sh
atlas
```

The same as `atlas tui --env prod`: it starts rela prod and the prod core in the background when they are not answering, and opens a TUI. The header says `Atlas · prod` in white on red; test's header says `Atlas · test`, plain.

More: `atlas status`, `atlas logs`, `atlas stop`, `atlas restart`; `atlas env` shows which environment a command works on.

rela keeps the description it started with. When a merge changes `rela/schema.yaml`, `atlas restart` (and `atlas`, when it starts the core) restarts rela on the new description first, its data kept, and says so: `rela prod ran an older description; restarted it`. `atlas status` says whether rela runs this build's description. When the new description no longer describes data rela holds (a removed kind or field that still has data), nothing starts: `atlas` names that data and the migration to run first (IS-Atlas-73).

## Where it runs

| | Test | Prod |
|---|---|---|
| rela | `eyra-atlas-test-rela` on Fly, private network only | 127.0.0.1:7590 |
| Control | `eyra-atlas-test` on Fly; this Mac's tunnel end 127.0.0.1:7693 | 127.0.0.1:7591 |
| Data | the apps' volumes on Fly | `~/.local/share/atlas/prod/` |

Both run the same pinned rela (26.10.14); test runs develop's newest build, prod the build on this Mac. Test and prod never connect: each has its own Bus, and a prod Bus or Control refuses a test message or client (and the other way round). Facts never move from test to prod.
