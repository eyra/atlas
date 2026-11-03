# Try UC-Atlas-06: Hand a scene to an agent

This guide grows with the use case, one section per issue. In the end Melle can see the agents, hand a scene to one (with or without a deadline), see the scene with that agent as owner and what it is expected to do ("Break it down into use cases and issues"), and see every open item with its owner, what is expected and whether it is late.

## IS-Atlas-17: the agents, each with what is assigned to it

The agents are one key away from the start page: `g Agents`, as `w What the agent did` is. Each row counts the Assignments that point at the agent: what is assigned to it.

It is all description (`rela/atlas.json`, kind `agent`):

- `start: {key: g, label: Agents}` puts the action on the start page. The kind stays `top: false`, so the start page is still the scenes list.
- `counts: [{relation: assigned_to, text: "{count} assigned"}]` makes each row count the facts that point at it through `assigned_to`. Control reads those facts plainly, without progress: one read per kind the relation starts at. A hint of that kind refreshes the list. A count whose read failed is left out, never shown as 0.

### Try

In test (`atlas tui --env test`):

| Step | Keys / command | What you should see |
|---|---|---|
| An agent | `atlas put agent --name Ada --env test` | `ada` |
| The agents | `g` on the start page | **Agents**: `ada  Ada  0 assigned`, and the coordinator with its count |
| Assign a scene to Ada | `atlas set SC-Atlas-NN assigned_to=ada --cause "handed to Ada" --env test` | Ada's row shows `1 assigned` at once, in every open TUI |
| What is assigned | `enter` on Ada | **Agent ada: Ada**, with the scene's Assignment under **Assignments** |

Hand a scene over once Flow has given it what is expected (a moment after it is made). Flow's first look on a new fact is a change of state, and a change of state moves the owner to the state's own (IS-Atlas-75). "Hand to…" (IS-Atlas-83) does this in one action.

In prod the coordinator's count includes the facts that were done before IS-Atlas-75. They kept the owner the IS-Atlas-52 migration gave them. Flow leaves a fact that becomes done from now on with no owner.

`e2e/scenarios/uc-atlas-06.exs` follows these steps.

## IS-Atlas-14: an optional deadline on the Assignment; late on read

The Assignment has an optional `deadline`, a date and time in UTC. Late is worked out on every read, as Progress is, and never stored. An Assignment is late while its deadline has passed and something is still expected of its owner, so while its fact is not done. Nothing else changes when it is late (SC-Atlas-02 step 9).

It is description, plus one general rule in State and Control:

- **`rela/schema.yaml`:** `deadline: { type: datetime }` on the assignment.
- **`rela/atlas.json`:** the assignment kind gets
  - `late: {after: deadline, while: expected, label: late}`;
  - `by_hand: "update"`: its page offers `u` to change it, and nothing to make or delete one, because an Assignment goes with its fact.
- **State:** it answers `late` with every fact of a kind with a late rule, plain reads too, and refuses a deadline that is not a date and time. rela itself would store one with only a warning.
- **Control:**
  - a page shows `Deadline  2026-11-04 17:00 UTC · late`;
  - a list row shows `Late · deadline 2026-11-04 17:00`, with late first so a narrow column never cuts it off;
  - a form takes `2026-11-04 17:00` (UTC) or any RFC 3339 time.

### Try

In test, with the scene from IS-Atlas-17 assigned to Ada:

| Step | Keys / command | What you should see |
|---|---|---|
| A deadline that has passed | `atlas set AS-SC-Atlas-NN deadline="2020-01-02 12:00" --env test` | On Ada's page (`g`, `enter` on Ada) the row says `Late · deadline 2020-01-02 12:00`. `atlas get SC-Atlas-NN` says `Deadline: 2020-01-02 12:00 UTC · late`. |
| One still to come | `atlas set AS-SC-Atlas-NN deadline=2099-01-02T12:00:00Z --env test` | `Deadline 2099-01-02 12:00`, not late |
| No time | `atlas set AS-SC-Atlas-NN deadline=tomorrow --env test` | Refused: `deadline must be a date and time, e.g. 2026-11-04T17:00:00Z` |
| By hand in the TUI | `enter` on the Assignment, `u` | **Update AS-SC-Atlas-NN** with **Deadline** (`2026-11-04 17:00`, UTC). Empty removes it. No `d`: an Assignment goes with its fact. |
| Done | accept the scene | Not late any more: nothing is expected once it is done. |

A page that is open when the deadline passes shows late from its next read: `r`, a hint, or the reconcile. Hand to… (IS-Atlas-83) will set the owner and the deadline in one action.
