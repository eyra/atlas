# Atlas prod

Prod holds the plan: real scenes, use cases and issues. Its data is real from the first write: never wipe it, and never run the end-to-end test or an experiment against it. Try things in test (`atlas tui --env test`) or on a private instance (`ATLAS_ENV_FILE`).

For now prod runs on this MacBook, like test, until it moves to Fly (IS-26; that move takes the data along).

## Start

```sh
atlas
```

The same as `atlas tui --env prod`: it starts rela prod and the prod core in the background when they are not answering, and opens a TUI. The header says `Atlas · prod` in white on red; test's header says `Atlas · test`, plain.

More: `atlas status`, `atlas logs`, `atlas stop`, `atlas restart`; `atlas env` shows which environment a command works on.

## Where it runs

| | Test | Prod |
|---|---|---|
| rela | 127.0.0.1:7690 | 127.0.0.1:7590 |
| Control | 127.0.0.1:7691 | 127.0.0.1:7591 |
| Data | `~/.local/share/atlas/test/` | `~/.local/share/atlas/prod/` |

Both run the same pinned rela (26.10.14) and the same build. Test and prod never connect: each has its own Bus, and a prod Bus or Control refuses a test message or client (and the other way round). Facts never move from test to prod.
