# Try UC-Atlas-28: My work on the front page

This guide grows with the use case. IS-Atlas-55: the TUI opens on what is assigned to you: your Assignments (IS-Atlas-78), each shown as the open fact it belongs to. Each row shows what is expected and since when and why. The header counts them on every page, and the scenes are one key away. IS-Atlas-54 (the "What to do" part of a fact's page) comes later.

## Start

```sh
atlas tui --env test
```

The TUI's user is `tui_user` in `env/<env>.json` (`melle`), and a person of that name must exist (`atlas put person --name Melle --env test`). Then the TUI opens on **Assigned to you**.

## Try

| Step | Keys / command | What you should see |
|---|---|---|
| Empty | `atlas` (or `atlas tui --env test`) | **Assigned to you**, and what fills it: `Nothing is assigned to you now. Flow assigns you what is your move (to test it, say), and anyone can with assigned_to. s opens the scenes.` The header: `Atlas · test · 0 assigned to you`. In prod today almost everything belongs to the coordinator, so this is what Melle sees until Flow writes owners (IS-Atlas-75). In test, anything assigned to `melle` before is there already. |
| One for you | in a second terminal: `atlas set UC-Atlas-NN assigned_to=melle --cause "all its issues are completed" --env test` | Within a second, in every open TUI: `UC-Atlas-NN  Its title`, and under it what is expected and why: `Build it · since 3 Nov 19:14 · all its issues are completed`. The header says `1 assigned to you`. |
| Newest first | assign a second one | It comes first. |
| Moved away | `atlas set UC-Atlas-NN assigned_to=coordinator --cause … --env test` | Gone, in every TUI; the count goes down. |
| The scenes | `s` | The scenes list, with the count in the header; `esc` comes back. |
| Open one | `↵` on a row | The fact's page (not its Assignment's), with **Assigned to** `melle` and the same since and cause. |
| Done | accept it (`a`, `y`), or merge an issue's pull request | Gone from the list: only open facts are there, though the Assignment still names you. |

A session that is not a person (an agent on the command line, a migration) opens on the plan, as before.

## How it works

- **The start page is data:** `start.assigned` in `rela/atlas.json`:
  - `relation`: the association whose inverse it reads, `assigned_to`;
  - `title`: "Assigned to you";
  - `count`: "{count} assigned to you", for the header;
  - `empty`: what fills it.
  - A kind's `start: {key, label}` puts its key on the start page. The scenes have `s Scenes`, and the agent's requests keep `w What the agent did`.
  - Every word comes from there, so naming these things (d-0022) is a change to `rela/atlas.json` only. No noun is in code.
- **Control:**
  - For a session whose user is a fact of a kind `assigned_to` points at (a person at the TUI), `/` is what points at it: its Assignments, one kind (IS-Atlas-78).
  - Each Assignment shows as the fact it belongs to: Control also reads the kinds the component association (`assignment`) starts at, only the facts whose Assignment points at the user (a `linked` read one step on), and finds each fact by its link to its Assignment. Completed facts are left out.
  - It sorts them by the time of the fact that set the link, newest first.
  - Each row has the fact's title, its expected action (the field the flow writes, on the Assignment since the flow is `on` it), and the since and cause of that link.
  - No kind is named: the relation is the description's `start.assigned.relation`, and the rest follows from the `component` mark.
  - Every page message carries `count`, which a client shows in its header. Control reads it again after a hint of any kind; the page itself follows every hint, as the start page always did.
- **TUI:** the header shows the count. A row whose detail is longer than its column shows the detail whole, under the row, so the cause is never cut. A list's empty text wraps.

## What changed for this

- **rela/atlas.json:** `start.assigned`; `start` on the scene kind.
- **Control:** the start page of assignments, and `count` on every page.
- **TUI:** the header count; long row details; wrapped empty text.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-28.exs`.
- **Changes to the e2e for every scenario:** `home()` presses `s` when the start page is the assignments, so every other scenario goes on from the scenes as before. Checks of the header title allow the count before it. UC-32 accepts a `melle` that exists already.
