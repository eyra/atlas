# Try UC-Atlas-02: Manage the use cases of a scene

What you can do: in a scene, add, open, change and remove use cases. A second TUI shows each change without refreshing.

Start everything as in `docs/guides/uc-atlas-01.md`: `bin/atlas up --env test` in one terminal, `bin/atlas tui --env test` in two more.

## Try

In TUI 1:

| Step | Keys | What you should see |
|---|---|---|
| A scene | `n`, a code such as `SC-Try-01`, ↓, a title, `ctrl-s` | The scene, and under it **Use cases**: `No use cases yet. Press a to add one.` |
| Add | `a`, a code such as `UC-Try-01`, ↓, a title, `ctrl-s` | `✓ Stored …`. The use case opens and shows `In scene SC-Try-01`. |
| Back | `esc` | The scene, with the use case in its list. Add a second one with `a`. |
| Open | ↑/↓ in the list, `enter` | The use case with all its fields. |
| Change | `e`, edit, `ctrl-s` | `✓ Stored …` and the changed use case. |
| Remove | `d`, then `y` | `✓ Stored …`. You are back in the scene, without it. |

Keep TUI 2 open on the same scene: every use case you add, change or remove in TUI 1 shows up there by itself (`updated by hint at …`).

Also try:

- **A wrong code.** Add a use case with code `SC-Wrong`. State refuses it (`id must start with UC-`). The form keeps what you typed.
- **Deleting a scene that has use cases.** In the scene, press `d`. It is refused: `still has 2 use cases. Remove them first`. Atlas never deletes use cases along with their scene.
- **Issues.** A use case already shows an empty **Issues** list, with `a` to add one. rela describes Issue already; UC-Atlas-03 is about testing that.

## What changed for this

- **rela's description:** Use case is described there, with the same fields as Scene, and in an `in_scene` relation, at most one scene per use case.
- **Control:** a page of any fact now lists the facts that point at it, adds new ones already pointing at it, and names the fact it points at.
- **State:** writes and reads links between facts, for any relation the description has.

Nothing in the Bus changed. No code anywhere names a use case.
