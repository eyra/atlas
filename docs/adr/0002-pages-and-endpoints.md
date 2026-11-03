# 0002: Pages and endpoints in the BFF contract

Status: accepted, 2026-11-03 (Melle: "Pages should also be part of the BFF. which pages the Control layer should serve. and possibly also Endpoints for form submits"; "also look at mica-bff for pages in the BFF"). UC-Atlas-35; this record comes with IS-Atlas-70 (pages); IS-Atlas-71 (form submits) and IS-Atlas-72 (the session's other calls) follow it.

## Context

The contract (`bff/contract`, ADR 0001) said what a page looks like: blocks and markup. Which pages exist was hand-written in Control (`AtlasControl.Pages.route/1`), and a block's destination was a free string. A client learned what Control serves only by following links, and nothing checked that a destination led anywhere.

mica-bff's spec format (`~/projects/nova/mica-bff/docs/adr/0001-spec-format.md`) plans the next layers of its spec: `defpage` for the pages its BFF serves and `defendpoint` for every other call. Atlas takes the ideas over and shares nothing with it (d-0009).

## Decision

1. **`defpage` in the contract.** A page has a name and a path; a segment `:name` is a parameter (a string). A page is always fetched and always returns a view model. The contract lists every page Control serves:

   | Page | Path |
   |---|---|
   | `home` | `/` |
   | `kinds` | `/_kinds` |
   | `list` | `/k/:kind` |
   | `new` | `/k/:kind/new` |
   | `new_under` | `/k/:kind/new/:relation/:parent` |
   | `item` | `/k/:kind/:key` |
   | `edit`, `delete` | `/k/:kind/:key/edit`, `/k/:kind/:key/delete` |
   | `links`, `set`, `remove` | `/k/:kind/:key/links/:relation`, `…/set/:relation`, `…/remove/:relation` |

2. **Page and endpoint stay separate concepts** (as in mica). A page is a fetch of a view model; an endpoint is any call. The DSL expands each page into the endpoint that fetches it (`call: :open`), so `__schema__/0` and `blocks.json` have one list of endpoints. Form submits (IS-Atlas-71) and the session's other calls (IS-Atlas-72) join that list as their own `defendpoint`s.

3. **The rules are the generator's** (`AtlasBFF.Paths`): parse a path, match a path to a page, build a page's path. Where two pages could match one path, a literal beats a parameter at the first segment where they differ (`/k/:kind/new` over `/k/:kind/:key`), so the order pages are written in does not matter; two pages with the same literals in the same places are refused at compile time. Values are percent-encoded in a path and decoded when matched.

4. **The targets give every consumer the pages.** The server and client targets define `pages/0`, `match/1` and `path/2`; the JSON target lists `pages` and `endpoints`. Control's router is the contract: `Pages.route/1` and `Pages.path/1` go through `match/1` and `path/2`, and a path outside the contract gets a "No such page" page. The TUI asks only for destinations that are pages of the contract. A test fails when a page Control renders names a destination that matches no page.

5. **Navigation belongs to the client** (as in mica). A block carries only its destination. The contract's pages let a client recognise what Control serves; the client decides how to show it.

### Where Atlas differs from mica

- **Pages take parameters.** mica's pages are named and parameterless (`defpage :home` → `GET /bff/page/home`). Atlas's pages are generic, for any kind rela describes: kind, key, relation and parent are parameters, never kind names (BEAM runs, rela describes).
- **Atlas keeps its paths.** mica derives the path from the page name. Atlas keeps `/k/<kind>/<key>` and the rest, because stored facts name them (an agent request's `page`), and because `_` (a kind made out from a key's prefix) and `_parent` (a kind's one parent relation) are parameter values an agent passes, resolved by Control from the description.
- **No HTTP.** mica's pages are GETs at `/bff/page/…`. Atlas's clients speak JSON lines over a socket (`bff/README.md`, Protocol); a page is fetched with `{"op": "open", "to": path}`. The endpoint's `call` names that message.

## Alternatives

| Option | Why not |
|---|---|
| Keep the router in Control | Every client would go on learning the pages only by following links, and nothing would check a destination. |
| Paths from page names, as mica | Facts already store today's paths; a new path for every page would break them and the agent requests that name them. |
| Pages per kind (`defpage :scene, …`) | Names a kind in the contract; a new kind would be a contract change instead of data in rela. |
| Order-dependent matching | A contract whose meaning changes when two lines swap. The rank rule, with a compile-time check for pages that match the same paths, has no order to get wrong. |

## Consequences

- A new page is a `defpage` in the contract and a clause in Control's `route/1`; the test that every contract page is served fails until both are there.
- Clients in other languages read the pages from `blocks.json` and implement `AtlasBFF.Paths`'s rules.
- The contract is 0.9.0. Its pages add to it; nothing a client renders changed.
