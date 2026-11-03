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
