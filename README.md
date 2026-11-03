# Atlas

Eyra's agent platform on BEAM: a central Bus with the layers State, Runtime, Organisation, Flow and Control, where no coordinator or agent can stay stuck and Melle only decides.

BEAM runs, rela describes: the BEAM side knows no entities; entities, schemas, flows and Organisation live in rela.

This repository holds everything during development: the BEAM application, the rela description, the Control spec and its clients (the TUI first).

## Try it

- `docs/guides/uc-atlas-01.md`: start the test environment and two TUIs, and manage scenes (UC-Atlas-01).
- `docs/guides/uc-atlas-02.md`: manage the use cases of a scene (UC-Atlas-02).
- `docs/guides/uc-atlas-03.md`: manage the issues of a use case (UC-Atlas-03).
- `docs/guides/uc-atlas-04.md`: link the pull requests of an issue (UC-Atlas-04).
- `docs/guides/uc-atlas-20.md`: long titles and descriptions of several lines and sections (UC-Atlas-20).

```sh
atlas tui     # starts what is needed in the background, then opens a TUI; again for a second one
atlas status  # what runs, and which build (also: atlas logs, atlas stop, atlas restart)
```

## Layout

| Path | What |
|---|---|
| `beam/` | The BEAM platform, an umbrella with one application per layer: `atlas_bus`, `atlas_state`, `atlas_control`. Layers depend on the Bus only and talk only over it. |
| `clients/tui/` | The TUI, a client of Control. Renders Control's blocks; knows no entity. Not part of the BEAM platform. |
| `spec/control/` | Control's spec: blocks, wire format, protocol. The spec itself is Elixir in `atlas_control`; `mix atlas.gen` makes server and client code from it. |
| `rela/` | rela's description (`schema.yaml`): every entity Atlas knows. `atlas.json` adds what this rela cannot hold, as data per kind: which fields a create asks for, how ids are made, defaults, fields only a connector fills. Plus the scripts that run the rela test instance. |
| `env/` | One settings file per environment (`test.json`), read by the core and the clients. |
| `bin/atlas` | The `atlas` command: starts the environment in the background and opens the TUI. `bin/atlas install` links it into `~/.local/bin` from the main clone. |
| `docs/guides/` | How to try each use case. |
| `e2e/` | The end-to-end test: one scenario per use case, run on a private instance with two TUIs in tmux. |

## Rules the tests check

- Layers talk only over the Bus: no layer depends on, calls or names another (`beam/apps/atlas_bus/test/boundary_test.exs`).
- Nothing on the BEAM side or in the TUI names an entity; entities live in `rela/schema.yaml` only (same test).
- The generated block code matches Control's spec (`mix atlas.gen --check`).

## Develop

```sh
cd beam && mix test          # Bus, State, Control (with a fake rela and a fake State)
cd clients/tui && mix test   # the TUI
cd beam && mix atlas.gen     # after changing Control's spec
bin/atlas e2e                # the end-to-end test (needs tmux); also: cd e2e && mix atlas.e2e
```

### The end-to-end test

`bin/atlas e2e` starts a private instance of its own: the pinned rela with a fresh, empty dataset on free ports, and the core, through `ATLAS_ENV_FILE`. It never touches `env/test.json`'s instance. Then it opens two real TUIs in tmux, drives them with keys and reads their screens. There is one scenario per use case in `e2e/scenarios/`, following its guide; `bin/atlas e2e uc-atlas-02` runs one.

A step fails when TUI 1 takes longer than 1 second after the key to show its stored change, or TUI 2 to show it by hint. The 5-second reconcile is a fallback, not the path. On a failure both screens, the logs and the error go to `e2e/artifacts/` (an artifact in CI). CI runs it on every pull request and on develop and master. A new use case adds its scenario in the same pull request as its code.

Elixir 1.18 on OTP 28 (`.tool-versions`). No dependencies outside OTP.
