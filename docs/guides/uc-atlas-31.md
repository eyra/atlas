# Try UC-Atlas-31: An issue has one pull request

What you can do: an issue is one change, so it has at most one pull request that is open or merged. Linking a second one is refused, and Atlas says which one is there and what to do (IS-Atlas-60). A closed, unmerged pull request does not count and stays on the issue as history.

## Start

The rule counts a pull request by its state, which State's GitHub connector reads. Test has no connector (d-0003), so a pull request linked in test has no state and never counts there. Try it in prod on a real issue, or in the end-to-end test (`bin/atlas e2e --env test uc-atlas-26`), which runs a stand-in GitHub.

## Try

| Step | Keys | What you should see |
|---|---|---|
| An issue with an open or merged pull request | open the issue | Its pull request shows `· Open` or `· Merged`. |
| Link a second one | `c`, a pull request URL, `ctrl-s` | `✗ Not sent: the form says why.` The form says `IS-Atlas-NN already has PR-… (Merged); an issue is one change: close that PR first, or make a new issue`. Nothing is stored. |
| From the command line | `atlas put pull_request --in IS-Atlas-NN --url … --json` | `{"refused": ["IS-Atlas-NN already has PR-… (Open); …"]}`, exit 1. |
| Closed on GitHub | close the first pull request without merging it; after a round of the connector, link the second | Accepted. The closed one stays on the issue's page as `Closed`. |
| Moving one there | `u` on a pull request of another issue, **In issue** set to this issue, `ctrl-s` | Refused the same way: a move links it too. |

Also try:

- **The same pull request again.** Linking the URL that is already on the issue is not a second one: it is the same pull request, as before.
- **Links that are there already** stay. IS-Atlas-28 keeps its two merged pull requests (#5 and #12); the rule checks new links only.

## What changed for this

- **rela's description:** `rela/atlas.json` gives the relation `in_issue` a `limit`: at most 1 pull request, counting only those whose `state` is `open` or `merged`, with the refusal's text (`{parent}`, `{child}`, `{value}` filled in). It is data: no code names a kind.
- **Control:** before a create under a parent, or a move to one, Control reads the facts that point at it through a limited relation and counts those whose field is one of the limit's values, never the fact itself. When the parent is full, nothing goes to State, and the form, or `atlas put` / `atlas set`, says why.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-26.exs` links a second pull request to the issue whose first is merged, in the TUI and with `atlas put`, and sees both refused. Its flaky pull request now goes to a second issue.

## An issue shows Development while its pull request is open (IS-Atlas-61)

Nobody runs `atlas set … stage=` for this any more. State works it out from the pull request, on every read, and stores nothing.

| Step | Keys / command | What you should see |
|---|---|---|
| An issue at specification | `atlas put issue --in UC-Atlas-NN --title … --env test` | Its row on the use case: `Specification`. |
| Its pull request is linked and open | `atlas put pull_request --url … --in IS-Atlas-NN --env test`, or `c` on the issue | Within a second its row shows `Development`. Its page says why: `Progress  Development · PR-… open`. The stored stage stays `specification`; a person or agent sets it, for the time before a pull request. |
| Merged | merge it on GitHub | After a connector round: `Done · PR-… merged` (UC-Atlas-32). |
| Closed without merging | close it on GitHub | After a connector round it counts no more: the stored stage shows again. |

The rule is data in `rela/atlas.json`, next to `completion`: the issue's `progress.while` is `[{ "over": "in_issue", "field": "state", "value": "open", "shows": "development" }]`. A draft is an open pull request, so it counts. `AtlasState.Progress` applies it with the same matching as completion. A pull request's change is a hint to the issue's page and to the pages above it. `e2e/scenarios/uc-atlas-31.exs` follows these steps on the stand-in GitHub.
