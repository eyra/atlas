# Atlas

Eyra's agent platform on BEAM: a central Bus with the layers State, Runtime, Organisation, Flow and Control, where no coordinator or agent can stay stuck and Melle only decides.

BEAM runs, rela describes: the BEAM side knows no entities; entities, schemas, flows and Organisation live in rela.

This repository holds everything during development: the BEAM application, the rela description, the Control spec and its clients (the TUI first).

## Try it

- `docs/guides/uc-atlas-01.md`: start the test environment and two TUIs, and manage scenes (UC-Atlas-01).
- `docs/guides/uc-atlas-02.md`: manage the use cases of a scene (UC-Atlas-02).
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

## Rules the tests check

- Layers talk only over the Bus: no layer depends on, calls or names another (`beam/apps/atlas_bus/test/boundary_test.exs`).
- Nothing on the BEAM side or in the TUI names an entity; entities live in `rela/schema.yaml` only (same test).
- The generated block code matches Control's spec (`mix atlas.gen --check`).

## Develop

```sh
cd beam && mix test          # Bus, State, Control (with a fake rela and a fake State)
cd clients/tui && mix test   # the TUI
cd beam && mix atlas.gen     # after changing Control's spec
```

Elixir 1.18 on OTP 28 (`.tool-versions`). No dependencies outside OTP.
