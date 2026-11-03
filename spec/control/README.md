# Control's spec

Control is a spec-driven backend for frontend (architecture, section 14). The spec says which blocks Control sends and every client renders. Clients know blocks, never entities: what a block shows comes from rela's description through Control.

mica-bff (`~/projects/nova/mica-bff`) was the inspiration for the format. Atlas shares no code, catalogue or package with it (d-0009).

## Where things are

| What | Where |
|---|---|
| The schema of the spec (the DSL: `defblock`, `defmodel`, `field`) | `beam/apps/atlas_control/lib/atlas_control/spec.ex` |
| The block catalogue, the spec itself | `beam/apps/atlas_control/lib/atlas_control/spec/blocks.ex` |
| The generators | `beam/apps/atlas_control/lib/atlas_control/spec/gen.ex`, run with `mix atlas.gen` in `beam/` |
| Generated server code (builders that check each block) | `beam/apps/atlas_control/lib/atlas_control/blocks.ex` |
| Generated client code for the TUI (structs, decoder with fallback) | `clients/tui/lib/atlas_tui/blocks.ex` |
| The catalogue as JSON, for clients in other languages | `spec/control/blocks.json` (this folder) |

Change the catalogue, run `cd beam && mix atlas.gen`, commit all three generated files. A test fails when they are out of date (`mix atlas.gen --check` does the same).

## Blocks (spec 0.1.0)

| Block | Shows | The user can |
|---|---|---|
| `list` | a title, rows, an empty text, actions | move, open a row, run an action |
| `item` | a title and labelled values | run an action (change, delete) |
| `form` | a title, inputs (text, choice, boolean, readonly), errors | fill it in, submit or cancel; a readonly input is shown, never changed |
| `confirm` | a question, or without `confirm_to` only why something cannot be done | confirm or go back |

Models that blocks hold: `action` (label, key, to), `row`, `pair`, `input`, `choice`. A page is a flat list of blocks; no block holds another block.

On the wire a block is `{"type": "list", "props": {...}}`. An optional prop without a value is left out. A client ignores unknown keys, and shows an unknown or broken block as a fallback while the rest of the page still renders.

## Protocol

JSON, one message per line, over TCP to the environment's Control address in `env/<env>.json`.

Client to Control:

| Message | Meaning |
|---|---|
| `{"op":"hello","env":"test","client":"tui","spec":"0.1.0"}` | First message. Control of another environment answers `bye` and closes. |
| `{"op":"open","to":"/k/<kind>/<key>"}` | Show the page at this path. |
| `{"op":"submit","to":"<form submit_to or confirm_to>","values":{...}}` | Submit a form or a confirm. Values travel as text. |
| `{"op":"refresh"}` | Reconcile: read the page again from State. Clients send it on an interval. |

Control to client:

| Message | Meaning |
|---|---|
| `{"op":"welcome","env":"test","spec":"0.1.0"}` | Answer to hello. |
| `{"op":"page","path","title","back","blocks","reason","position","at"}` | A page. `reason` is `open`, `hint` (a change stored by anyone), `reconcile`, `stored` (your change) or `refused`. `position` is State's position the page is as of. |
| `{"op":"notice","tone":"pending\|ok\|error\|info","text","at"}` | A line for the status bar. `pending` until State answers. |
| `{"op":"bye","text"}` | Control closes the connection. |

Paths are Control's own (`/`, `/k/<kind>`, `/k/<kind>/new`, `/k/<kind>/<key>`, `.../edit`, `.../delete`); a client only follows them.
