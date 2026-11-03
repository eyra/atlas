# Try UC-Atlas-20: Write long titles and descriptions

What you can do: give a scene, use case or issue a title longer than its field, and a description of several lines and sections. Both are stored and shown as you wrote them.

## Start

```sh
atlas tui --env test
```

(See `docs/guides/uc-atlas-01.md` for what it starts. Open a second TUI with `atlas tui --env test` in another terminal to watch the changes arrive there.)

## Try

| Step | Keys | What you should see |
|---|---|---|
| A long title | `n`, type a title longer than the field | The title wraps onto the next row of its field; nothing is cut off. `enter` or ↓ goes on to the description. |
| A description | ↓ into **Description**, type `## Why`, `enter`, `enter`, a paragraph, `enter`, `enter`, `## What`, `enter`, `- one`, `enter`, `- two` | The description is a text area: `enter` starts a new line, blank lines stay. The help line says `↵ new line   ↑↓←→ move   tab next field   ctrl-s save`. |
| Move around | ↑ ↓ ← →, Home, End, backspace | The cursor (a reversed cell) moves between lines and within a line; typing goes where it is; backspace at the start of a line joins it to the line above. ↑ on the first line or ↓ on the last leaves the description; `tab` always goes on to the next field. |
| A long description | keep typing lines | Longer than the screen, the text area scrolls around the cursor and says how much is out of sight (`↑ 4 more above · ↓ 2 more below`). |
| Save | `ctrl-s` | `✓ Stored as SC-Atlas-NN`, and the scene opens. Its title wraps under the label; its description shows with its line breaks, blank lines, headings (bold) and lists (a wrapped list item continues under its own text). |
| Two parts (IS-Atlas-48) | open a scene, a use case or an issue with a long description | The page has two parts: **Content** (the item, its fields and description) and **References** (its use cases, issues or pull requests, and what it is in). From 120 columns they are side by side, narrower one above the other. The description never pushes the references out of view: when it is longer than its part, the part ends in `… N more lines`. |
| Scroll the content | `tab`, then ↑/↓ (or `pgup`/`pgdn`) | The focus moves to the content (its frame lights up; the help line says `↑↓ scroll`). The description scrolls on its own (`↑ N lines above`); the references stay where they are. `tab` again goes back to the references, where ↑/↓ move the selected row. |
| Resize | make the terminal wider or narrower | The parts go side by side or one above the other at once. |
| Change | `e`, ↓ to **Description**, edit, `ctrl-s` | The change form opens the description with all its lines; ↓ into it starts at its first line, ↑ into it from below at its end. |

In TUI 2, the scene changes by itself after each save (`updated by hint at …`), with the same lines.

## What changed for this

- **rela's description:** `rela/atlas.json` marks `description` as `multiline` for each kind that has one. That is the only place that says a field takes several lines; no code names a field or a kind.
- **Control:** sends such a field as a form input of kind `multiline` (a new value of `input.kind` in Control's spec; the shape of the spec did not change).
- **TUI:** wraps long text fields, edits `multiline` inputs as a text area, keeps line breaks on item pages, and scrolls pages longer than the screen.
- **rela** stores the line breaks as they are typed.
- **Two parts (IS-Atlas-48):** Control sends every item page as two parts in its markup: `columns` over the page, a "Content" border around the item, and a "References" border around its lists, the facts it points at among them. The TUI lays out a page whose markup puts it in columns as parts: side by side when wide, else one above the other with the references given room first, each scrolled on its own, `tab` between them; it redraws when the terminal is resized. No code names a kind.
