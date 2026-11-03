# Try UC-Atlas-32: Completed means accepted or merged

What you can do: see who accepted a use case or scene, since when, by whom and why, without a `completed` field anywhere. Completable is an association in rela: a kind has it when it is in `accepted_by`'s `from`. The link has no attributes; the fact that set it carries when, by whom and why, and State answers the link with that fact.

This guide grows with the use case. IS-Atlas-62 (this part): the person kind, `accepted_by`, `done_in` as history, and the migration of prod. IS-Atlas-63 works out "completed" and "To test"; IS-Atlas-64 adds Accept (`a`) and Reopen (`r`) for a person only.

## Start

```sh
atlas tui --env test
```

## Try

| Step | Keys / command | What you should see |
|---|---|---|
| A person | `atlas put person --name Melle --env test` | `Person melle: Melle`. The id is made from the name, in lower case. People are not on the start page; the scenes list still is. |
| Accept a use case | open a use case in the TUI; in a terminal `atlas set UC-Atlas-NN accepted_by=melle --cause "tested it" --env test` | Within a second the page shows `Accepted by  melle` and under it, dim: `since 3 Nov 15:10 · by agent · tested it`. `atlas get UC-Atlas-NN --env test` shows the same line; `--json` gives it as `origins` (`since`, `by`, `cause`). |
| Remove it | `atlas set UC-Atlas-NN accepted_by= --cause "found a bug" --env test` | `Accepted by  —` with `… · by agent · found a bug`. Every earlier link stays in State as the link's history. |
| No completed field | `atlas help use_case --env test`; `atlas help issue --env test` | No `completed` field, and issue stages are specification, design, development. `use_case` lists `Links: accepted_by: to person, at most one`. |
| History only | `atlas set IS-Atlas-NN done_in=PR-… --env test` | Refused: `Also done in is not set here: only a migration sets it.` `atlas tools` does not offer it. |

`by` says who sent the fact: the TUI is `tui_user` from the environment's settings (`melle`), the command line is `agent`, the migration is `migration`. IS-Atlas-64 lets only a person accept.

## Prod: the migration (for the coordinator, after the merge)

The description changes, so rela has to restart on it, then the data follows. Dry run first:

```sh
cd ~/projects/eyra/atlas            # on develop, with this merged
atlas rela-stop --env prod          # rela reads the new schema.yaml when it starts
atlas restart --env prod            # starts rela again, and the core of this build
atlas migrate-completion --env prod --dry-run
atlas migrate-completion --env prod
```

The dry run prints every step and writes nothing. On prod today that is 47 steps, each one fact with the cause `completion becomes an association (UC-Atlas-32)`:

- the person `melle`;
- `accepted_by` melle on UC-Atlas-01, 02, 03 and 04 (the ones with completed=true; no scene has it);
- 30 issues from stage testing to development;
- `done_in` for the 12 issues done in another issue's pull request: IS-Atlas-02 to 07 in PR #1, IS-Atlas-08 in PR #2, IS-Atlas-12 and 34 to 37 in PR #14 (`tools/plan/done_in.json`).

The real run then stops rela, removes the old `completed` values with rela's own `rela migrate gc` (rela keeps a removed field's values and refuses to change them over its API), and starts rela again. A second run finds nothing to do.

Check: `atlas get UC-Atlas-01 --env prod` shows `Accepted by: melle (since …, by migration: completion becomes an association (UC-Atlas-32))`; `atlas get IS-Atlas-34 --env prod` shows `Also done in: PR-eyra-atlas-14`.

This PR and IS-Atlas-63 merge together, then the migration runs: without IS-Atlas-63 nothing would show Done, since Done came from the `completed` field.

## What changed for this

- **rela's description:** `rela/schema.yaml` has a `person` kind (name; id made from it) and two associations: `accepted_by` (scene, use case → person, at most one, inverse `accepted`) and `done_in` (issue → pull request, inverse `also_done`). `completed` and the stage `testing` are gone. `rela/atlas.json` marks the parent relations (`relations.<name>.parent`: in_scene, in_use_case, in_issue), so an association with at most one link is never taken for a parent; `done_in` is `set_by: migration`; `person` is `top: false` (not on the start page).
- **State:** a change may set or remove the links of the relations it names. State records the fact that set each link (when, position, by, cause) in `links.dets` in its data folder, and answers each link with its `origins`, and one fact with the `history` of its links.
- **Control:** a page shows each association with the fact that set it (`pair.origin` in the contract, 0.7.0). `/k/<kind>/<key>/links/<relation>` sets or removes an association's links, with a note as its cause; parents and `set_by` associations are refused there. Each fact carries `by`: who is on the session. A submit may carry a `cause`.
- **Clients:** the TUI shows the origin dim under the value. `atlas set <key> <association>=<key>` sets a link, empty removes it, and `--cause` says why (put and set). `atlas get --json` gives `origins`.
- **Tools:** `atlas migrate-completion` (`tools/plan`, `AtlasPlan.Completion`).
