# Atlas

Eyra's agent platform on BEAM: a central Bus with the layers State, Runtime, Organisation, Flow and Control, where no coordinator or agent can stay stuck and Melle only decides.

BEAM runs, rela describes: the BEAM side knows no entities; entities, schemas, flows and Organisation live in rela.

This repository holds everything during development: the BEAM application, the rela description, the Control spec and its clients (the TUI first).

## Try it

`atlas` opens **prod**, where the plan lives (real data; the header shows `Atlas · prod` in white on red). Try use cases in **test**: `atlas tui --env test`. Scripts, tests and agents always pass `--env test` or a private `ATLAS_ENV_FILE`.

- `docs/guides/prod.md`: the prod environment: start, stop, where its data is.
- `docs/guides/uc-atlas-01.md`: start the test environment and two TUIs, and manage scenes (UC-Atlas-01).
- `docs/guides/uc-atlas-02.md`: manage the use cases of a scene (UC-Atlas-02).
- `docs/guides/uc-atlas-03.md`: manage the issues of a use case (UC-Atlas-03).
- `docs/guides/uc-atlas-04.md`: link the pull requests of an issue (UC-Atlas-04).
- `docs/guides/uc-atlas-16.md`: the agent's tools, and a plan for a request that writes nothing (UC-Atlas-16).
- `docs/guides/uc-atlas-17.md`: press `:` on any page, say what you want, and decide on the agent's plan (UC-Atlas-17).
- `docs/guides/uc-atlas-18.md`: watch the agent's steps go one by one, and stop it with `esc` (UC-Atlas-18).
- `docs/guides/uc-atlas-19.md`: see what the agent did: `w` on the start page lists every request, its outcome and steps (UC-Atlas-19).
- `docs/guides/uc-atlas-20.md`: long titles and descriptions of several lines and sections (UC-Atlas-20).
- `docs/guides/uc-atlas-25.md`: how far a scene and its use cases are, from the issues under them (UC-Atlas-25).
- `docs/guides/uc-atlas-26.md`: each pull request's title and state from GitHub, read by State's GitHub connector (UC-Atlas-26).
- `docs/guides/uc-atlas-30.md`: move an item to another parent, in the TUI and with `atlas set` (UC-Atlas-30, IS-Atlas-59).
- `docs/guides/uc-atlas-31.md`: an issue has one open or merged pull request; a second is refused, and says why (UC-Atlas-31, IS-Atlas-60).

```sh
atlas                     # prod: starts what is needed in the background, then opens a TUI
atlas tui --env test      # the same for test; again for a second one
atlas status --env test   # what runs, and which build (also: logs, stop, restart, env)
```

## Driving Atlas from an agent

Agents use the same Control as the TUI, from the command line: `atlas help`, `put`, `set`, `delete`, `get`, `list`. Nothing writes rela directly. The same rules, refusals and generated codes apply, and an open TUI shows each change at once. `atlas help` (or `atlas put --help`) lists the kinds, what a create asks, how ids are made, what a kind belongs under and its fields, all from rela's description. Every command takes `--json` and then prints one JSON value: the item, the list, or `{"refused": [...]}`. The exit status is 0 when done, 1 when refused (the reasons also go to stderr) and 2 on an error. Like `atlas`, it works on prod unless given `--env test`.

```sh
atlas put use_case --in SC-Atlas-05 --title "Read items from the command line" --description-file uc.md --json
atlas set IS-Atlas-33 stage=testing --json
atlas put pull_request --url https://github.com/eyra/atlas/pull/14 --in IS-Atlas-33 --json
```

An agent that plans gets the same actions as tools: `atlas tools` lists them, made from rela's description through Control. `atlas plan --on <code> "<request>"` asks the environment's planner (`agent.planner` in `env/<env>.json`: a local `claude -p` that may only read, or any command) what it would do on that page. It answers steps, each checked against the form it would fill, and writes nothing (UC-Atlas-16). In the TUI, `:` asks the same agent (`atlas steer`, which the TUI starts) about the page you are on; you keep, edit or drop each step, and `enter` runs the kept ones through Control (UC-Atlas-17).

`--in <code>` names the parent, `--<field>-file <path>` or `--<field> -` (stdin) reads text of several lines, and `atlas get <code>` and `atlas list <kind> [--in <code>]` read. `atlas load-plan <SCENES.md> tools/plan/links.json [--dry-run]` loaded the plan from SCENES.md this way (UC-Atlas-05). It never changes an existing item, and when a code is taken it maps it to the next one.

## Layout

| Path | What |
|---|---|
| `beam/` | The BEAM platform, an umbrella with one application per layer: `atlas_bus`, `atlas_state`, `atlas_control`. Layers depend on the Bus only and talk only over it. Connectors to outside systems sit at State's edge, in `atlas_state`; GitHub, read-only, is the first. |
| `clients/tui/` | The TUI, a client of Control. Renders Control's blocks; knows no entity. Not part of the BEAM platform. |
| `clients/agent/` | The agents' command line (`atlas help/put/set/get/list/tools/plan`), a client of Control like the TUI: it reads pages and fills forms, and knows no entity. The planner boundary (`AtlasAgent.Planner`) is here too. |
| `tools/plan/` | `atlas load-plan` (UC-Atlas-05): SCENES.md into Atlas through `clients/agent`, with `links.json` for pull requests and stages. |
| `bff/` | Control's BFF (backend for frontend), in three parts (ADR 0001): `generator/` (the DSL, the rules of markup, the targets, `mix atlas.gen`; none of Atlas's values), `contract/` (the blocks, models and markup Control sends; only that), `targets/` (generated files: `json/blocks.json` for clients in other languages). Control and the TUI read the contract at compile time. `bff/README.md` has the view model, the wire format and the protocol. |
| `rela/` | rela's description (`schema.yaml`): every entity Atlas knows. `atlas.json` adds what this rela cannot hold, as data per kind: which fields a create asks for, how ids are made, defaults, fields only a connector fills. Plus the scripts that run the rela test instance. |
| `env/` | One settings file per environment (`test.json`, `prod.json`), read by the core and the clients. Test and prod share no port and no data. |
| `bin/atlas` | The `atlas` command: starts the environment in the background and opens the TUI. `bin/atlas install` links it into `~/.local/bin` from the main clone. |
| `docs/guides/` | How to try each use case. |
| `docs/adr/` | Decisions, one short record each. |
| `e2e/` | The end-to-end test: one scenario per use case, run on a private instance with two TUIs in tmux. |

## Rules the tests check

- Layers talk only over the Bus: no layer depends on, calls or names another (`beam/apps/atlas_bus/test/boundary_test.exs`).
- Nothing on the BEAM side, in the TUI or in the agents' command line names an entity; entities live in `rela/schema.yaml` only (same test).
- The generated files match the contract, and none is left over (`mix atlas.gen --check` in `bff/contract`).
- The generator holds none of Atlas's values and compiles without the contract; its targets read only `__schema__/0`.

## Develop

```sh
cd beam && mix test          # Bus, State, Control (with a fake rela and a fake State)
cd clients/tui && mix test   # the TUI
cd clients/agent && mix test # the agents' command line: tools, planner
cd bff/generator && mix test   # the DSL, the rules of markup, the targets (on a neutral contract)
cd bff/contract && mix atlas.gen   # after changing the contract: writes bff/targets/
bin/atlas e2e --env test     # the end-to-end test (needs tmux); never on prod; also: cd e2e && mix atlas.e2e
cd e2e && mix test           # what bin/atlas refuses or chooses (prod default, --env, ATLAS_ENV_FILE)
```

### The end-to-end test

`bin/atlas e2e` starts a private test instance of its own: the pinned rela with a fresh, empty dataset on free ports, and the core, through `ATLAS_ENV_FILE` and `--env test`. It never touches `env/test.json`'s or `env/prod.json`'s instance, and refuses `--env prod`. Then it opens two real TUIs in tmux, drives them with keys and reads their screens. There is one scenario per use case in `e2e/scenarios/`, following its guide; `bin/atlas e2e --env test uc-atlas-02` runs one.

A step fails when TUI 1 takes longer than 1 second after the key to show its stored change, or TUI 2 to show it by hint. The 5-second reconcile is a fallback, not the path. On a failure both screens, the logs and the error go to `e2e/artifacts/` (an artifact in CI). CI runs it on every pull request and on develop and master. A new use case adds its scenario in the same pull request as its code.

Elixir 1.18 on OTP 28 (`.tool-versions`). No dependencies outside OTP.
