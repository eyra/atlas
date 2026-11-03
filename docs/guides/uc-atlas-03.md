# Try UC-Atlas-03: Manage the issues of a use case

What you can do: in a use case, add, open, change and remove issues. A second TUI shows each change without refreshing.

Start everything as in `docs/guides/uc-atlas-01.md`: `bin/atlas up --env test` in one terminal, `bin/atlas tui --env test` in two more.

## Try

In TUI 1:

| Step | Keys | What you should see |
|---|---|---|
| A use case | `n` for a scene (`SC-Try-01`), then `a` in it for a use case (`UC-Try-01`) | The use case, and under it **Issues**: `No issues yet. Press a to add one.` |
| Add | `a`, a code such as `IS-Try-01`, ↓, a title, ↓ and ←/→ for the stage, `ctrl-s` | `✓ Stored …`. The issue opens and shows `In use case UC-Try-01`. |
| Open | `esc` back to the use case, ↑/↓, `enter` | The issue with all its fields: stage, completed, Flux ref. An issue has no status. |
| Change | `e`, change the stage, set completed to yes, type a Flux ref such as `NEXT-240`, `ctrl-s` | `✓ Stored …` and the changed issue. |
| Remove | `d`, then `y` | `✓ Stored …`. You are back in the use case, without it. |

Keep TUI 2 open on the same use case or issue: each change shows up there by itself (`updated by hint at …`).

Also try:

- **A wrong code.** Add an issue with a code that does not start with `IS-`. State refuses it, and the form keeps what you typed.
- **Deleting a use case that has issues.** In the use case, press `d`. It is refused: `still has 1 issue`.
- **Pull requests.** An issue already shows an empty **Pull requests** list. UC-Atlas-04 is about linking them.

## What changed for this

Nothing on the BEAM side or in the TUI, apart from one wording fix: a count of one now uses the kind's own label ("1 issue"). Issue, its fields and its `in_use_case` relation are in rela's description. Control builds the issue's form, its page and the related list from that description, with the same code as for scenes and use cases.
