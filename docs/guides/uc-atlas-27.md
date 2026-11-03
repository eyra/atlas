# Try UC-Atlas-27: Every fact has an owner

This guide grows with the use case. IS-Atlas-52: the owner is an association in rela, `assigned_to`. It goes from every assignable kind (scene, use case, issue, pull request) to a person or an agent, one at most. The link has no attributes: when, by whom and why are the fact that set it, and pages and `atlas get` show them with it. IS-Atlas-53 (Flow) moves owners later.

## Try

In prod, after the migration below, every fact has an owner:

| Step | Where | What you should see |
|---|---|---|
| An owner | `atlas get UC-Atlas-01 --env prod` | `Assigned to: coordinator (since 3 Nov …, by migration: owner introduced)`, and under it the list **Assigned to** with `coordinator  Agent`. `--json` gives `origins["Assigned to"]`: `since`, `by` and `cause`. |
| On its page | any scene, use case, issue or pull request in the TUI | **Assigned to** in the content, with since, by and cause, and in the references, the owner as a row. |
| The owner's page | `enter` on that row, or `atlas get coordinator --env prod` | **Agent coordinator**, with what is assigned to it, one list per kind: **Assignments: Scenes**, **Assignments: Use cases**, … Melle's page (`atlas get melle`) the same for Melle. |
| Change it | `atlas set UC-Atlas-01 assigned_to=melle --cause "all 12 issues completed" --env test`, or `u` on the page (**Assigned to**, a person or an agent, `ctrl-s`) | One owner, the new one, with its own since, by and cause. The earlier owner stays in the facts as history. |
| Only who can own | `atlas set UC-Atlas-01 assigned_to=nobody --env test` | Refused: `nobody is not a person or agent`. |

Try changes in test (`--env test`), not prod: prod is real data.

## The prod data: `atlas migrate-owner`

Every fact that exists gets the coordinator as its owner, one fact each, with the cause "owner introduced". The coordinator runs it after the merge, once prod's rela has restarted on the new description:

```sh
atlas migrate-owner --env prod --dry-run   # prints every step; writes nothing
atlas migrate-owner --env prod             # writes them through Control, as the migration
atlas migrate-owner --env prod --dry-run   # again: 0 steps
```

What it does:
1. It makes the agent `coordinator` (Coordinator) when there is none.
2. It sets `assigned_to` coordinator on every fact of a kind in `assigned_to`'s `from` that has no owner yet. It reads that list from rela's description, so a kind added there is included.

It reads rela read-only and writes only through Control. A fact that has an owner keeps it, so a second run does nothing.

Tried on a private instance with prod's shape (prod's facts copied in with reads only): 147 steps (the agent, and 6 scenes, 34 use cases, 69 issues and 37 pull requests) in 49 s, then 0.

## How it works

- **rela's description:**
  - `rela/schema.yaml` has an `agent` kind next to `person` (made from a name, not on the start page; `rela/atlas.json`).
  - It has `assigned_to` from scene, use case, issue and pull request to person and agent, with `max_outgoing: 1` and the inverse `assignments`.
  - A kind is assignable by being in `assigned_to`'s `from`; adding one is a change to the description only.
- **A relation to several kinds:**
  - rela links each key with its kind, but answers only the keys. State finds out which kind a key is by reading it in each kind the relation points at, both on a write and when it answers one fact (`link_kinds`).
  - A key of none is refused. Control opens it as that kind, and offers the facts of every such kind on the links page.
- **A relation from several kinds:** the page it points at has one list per kind (`Assignments: Scenes`, …). As for any association, a list shows only when it has something.
- **A key without an id prefix** (`melle`, `coordinator`): when more than one kind has no prefix, Control asks State which one has it, for `atlas get <key>`.
- **No kind is named** in BEAM, the TUI or the agent. The words a page shows ("Assigned to", "Assignments") are the relation's label and inverse label in the description, so naming them otherwise (d-0022) is a one-line change there.

## What changed for this

- **rela:** `agent`; `assigned_to`.
- **State:** relations to several kinds; `link_kinds` in a fact's answer.
- **Control:** lists per kind for a relation from several; rows and the links page for one to several; keys without a prefix.
- **tools/plan:** `AtlasPlan.Owner` and `atlas migrate-owner`.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-27.exs`.
- **Prod:** restart rela (it reads `schema.yaml` when it starts) and the core, then run the migration.
