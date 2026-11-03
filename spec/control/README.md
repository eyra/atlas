# Control's spec

Control is a spec-driven backend for frontend (architecture, section 14). The spec says which blocks Control sends and every client renders. Clients know blocks, never entities: what a block shows comes from rela's description through Control.

mica-bff (`~/projects/nova/mica-bff`) was the inspiration for the format. Atlas shares no code, catalogue or package with it (d-0009).

## Where things are

The spec is Elixir: the block catalogue is written in a small DSL and is the single source. Everything else is generated from it.

| What | Where |
|---|---|
| The block catalogue, the spec itself (source, edit this) | `spec/control/blocks.ex` (this folder) |
| The DSL: `version`, `defblock`, `defmodel`, `defmarkup`, `field`, and its compile-time checks | `beam/apps/atlas_control/lib/atlas_control/spec.ex` |
| The rules of markup (nesting, the tree, delete, move, place), as tested functions; Control and the TUI both compile them | `spec/control/rules/markup.ex` (`AtlasSpec.Markup`) |
| The generators | `beam/apps/atlas_control/lib/atlas_control/spec/gen.ex`, run with `mix atlas.gen` in `beam/` |
| Generated server code (builders that check each block) | `beam/apps/atlas_control/lib/atlas_control/blocks.ex` |
| Generated client code for the TUI (structs, decoder with fallback) | `clients/tui/lib/atlas_tui/blocks.ex` |
| Generated catalogue as JSON, for clients in other languages | `spec/control/blocks.json` (this folder; never edit it) |

A block in the catalogue:

```elixir
defblock :form do
  field :title, :string, required: true
  field :inputs, {:list, :input}, required: true
  field :submit_label, :string, required: true
  field :submit_to, :string, required: true
  field :cancel_to, :string
  field :errors, {:list, :string}
end
```

Types are `:string`, `:integer`, `:boolean`, a model (`defmodel`), or `{:list, type}`. `blocks.ex` compiles into Control (`elixirc_paths` in `atlas_control/mix.exs`), so a mistake fails the build and points at its line:

- in the catalogue: an unknown type, a name or field defined twice, a block that holds a block, a field that holds markup, a name that is not snake_case, an option other than `required:`, a missing `version`;
- in Control's code: a builder call (`Blocks.form(title: ..., ...)`) that leaves out a required prop or names one the block does not have. The builders are macros, so a caller writes `require AtlasControl.Blocks, as: Blocks`. A wrong value, or a required prop that is `nil` at run time, raises when the block is built.

Change the catalogue, run `cd beam && mix atlas.gen`, commit the catalogue and the three generated files. A test fails when they are out of date, and CI runs `mix atlas.gen --check`.

The DSL is plain macros (`AtlasControl.Spec`, about 170 lines), not Spark: a catalogue of a few blocks and models needs only entries, typed fields and a handful of checks, and plain macros keep it without a dependency. Markup is one more kind of entry, `defmarkup`, beside `defblock` and `defmodel`.

## View model (spec 0.2.0)

Control sends a view model, not a data model: its **content**, a flat list of blocks, and its **markup**, entries that cover a stretch of those blocks. Every block has an id, stable for as long as the page shows the same thing; markup points at ids, never at positions, so inserting, deleting or moving a block (or a hint that changes one) never shifts other markup.

### Blocks

| Block | Shows | The user can |
|---|---|---|
| `list` | rows, an empty text, actions; a title, unless a section carries it | move, open a row, run an action |
| `item` | a title and labelled values | run an action (change, delete) |
| `form` | a title, inputs (text, multiline, choice, boolean, readonly), errors | fill it in, submit or cancel; a long text wraps; a multiline input takes several lines (enter starts a new line); a readonly input is shown, never changed |
| `confirm` | a question, or without `confirm_to` only why something cannot be done | confirm or go back |

Models that blocks hold: `action` (label, key, to), `row`, `pair`, `input`, `choice`. No block holds another block; grouping is markup.

On the wire a block is `{"id": "item", "type": "list", "props": {...}}`. An optional prop without a value is left out. A client ignores unknown keys, and shows an unknown or broken block as a fallback while the rest of the page still renders.

### Markup

| Kind | Props | The TUI draws |
|---|---|---|
| `section` | `title`, `collapsible` | a heading with a rule, above its blocks |
| `border` | `title` (optional) | a box around its blocks |
| `columns` | `count` | not yet: its blocks show one under the other |
| `highlight` | `tone` (info, ok, error, pending) | not yet: its blocks show as they are |

On the wire an entry is `{"kind": "section", "start": "<block id>", "end": "<block id>", "props": {...}}`, covering `start` to `end`, both included, with `"group"` on the pieces of split markup.

All markup nests, of every kind, as in XML: two entries share no block, or one covers all of the other. Entries over the same stretch nest in list order, the first outermost. So a view model's markup is one well-formed tree, which a client renders top down. Markup that would cross (a highlight over the end of one section and the start of the next) is placed as pieces that each nest and share a group id. The rules, as functions with tests, are `AtlasSpec.Markup` in `spec/control/rules/markup.ex`:

- `check/2`: refuses crossing markup, an unknown block id, an end before its start, an id used twice. Control's `Blocks.view_model/2` raises on it, so Control never sends bad markup; a client leaves out markup that fails it and shows the blocks flat.
- `tree/2`: the tree a client renders.
- `delete/3`: a deleted boundary block moves the boundary to its neighbour inside the stretch; an entry left empty is dropped.
- `move/4`: a moved block keeps an entry only while it stays inside the stretch, and joins those it lands inside; markup of the block alone moves with it.
- `place/3`: adds an entry, split into grouped pieces where it would cross.

Today an item page puts the item in a `border` and each related list in a `section` carrying its title (a scene: the scene in a border, then a "Use cases" section).

The names (view model, markup) live in one place: the attributes at the top of `gen.ex`, plus the `defmarkup` macro in `spec.ex` and the module name `AtlasSpec.Markup`.

## Protocol

JSON, one message per line, over TCP to the environment's Control address in `env/<env>.json`.

Client to Control:

| Message | Meaning |
|---|---|
| `{"op":"hello","env":"test","client":"tui","spec":"0.2.0"}` | First message. Control of another environment answers `bye` and closes. |
| `{"op":"open","to":"/k/<kind>/<key>"}` | Show the page at this path. |
| `{"op":"submit","to":"<form submit_to or confirm_to>","values":{...}}` | Submit a form or a confirm. Values travel as text. |
| `{"op":"refresh"}` | Reconcile: read the page again from State. Clients send it on an interval. |

Control to client:

| Message | Meaning |
|---|---|
| `{"op":"welcome","env":"test","spec":"0.2.0"}` | Answer to hello. |
| `{"op":"page","path","title","back","blocks","markup","reason","position","at"}` | A page: a view model (`blocks` and `markup`) with its path, title and way back. `reason` is `open`, `hint` (a change stored by anyone), `reconcile`, `stored` (your change) or `refused`. `position` is State's position the page is as of. |
| `{"op":"notice","tone":"pending\|ok\|error\|info","text","at"}` | A line for the status bar. `pending` until State answers. |
| `{"op":"bye","text"}` | Control closes the connection. |

Paths are Control's own (`/`, `/k/<kind>`, `/k/<kind>/new`, `/k/<kind>/<key>`, `.../edit`, `.../delete`); a client only follows them.
