# Atlas

Eyra's agent platform on BEAM: a central Bus with the layers State, Runtime, Organisation, Flow and Control, where no coordinator or agent can stay stuck and Melle only decides.

BEAM runs, rela describes: the BEAM side knows no entities; entities, schemas, flows and Organisation live in rela.

This repository holds everything during development: the BEAM application, the rela description, the Control spec and its clients (the TUI first).

## Try it

`docs/guides/uc-atlas-01.md`: start the test environment and two TUIs, and manage scenes (UC-Atlas-01).

```sh
bin/atlas up  --env test   # rela test (background) and the core (foreground)
bin/atlas tui --env test   # a TUI; open a second one beside it
```

## Layout

| Path | What |
|---|---|
| `beam/` | The BEAM platform, an umbrella with one application per layer: `atlas_bus`, `atlas_state`, `atlas_control`. Layers depend on the Bus only and talk only over it. |
| `clients/tui/` | The TUI, a client of Control. Renders Control's blocks; knows no entity. Not part of the BEAM platform. |
| `spec/control/` | Control's spec: blocks, wire format, protocol. The spec itself is Elixir in `atlas_control`; `mix atlas.gen` makes server and client code from it. |
| `rela/` | rela's description (`schema.yaml`): every entity Atlas knows. `atlas.json` adds what this rela cannot hold, as data per kind: which fields a create asks for, how ids are made, defaults, fields only a connector fills. Plus the scripts that run the rela test instance. |
| `env/` | One settings file per environment (`test.json`), read by the core and the clients. |
| `bin/atlas` | Starts the environment and the TUI. |
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
