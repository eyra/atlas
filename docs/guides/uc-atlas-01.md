# Try UC-Atlas-01: Manage scenes

What you can do: start the TUI with `--env test`; list, create, open, change and delete scenes; a second TUI shows each change without refreshing.

Test environment only, on this MacBook. Nothing touches prod, Fly or the live rela store.

## Start

You need three terminals, all in the Atlas repository.

1. **The core** (rela, Bus, State, Control):

   ```sh
   bin/atlas up --env test
   ```

   It starts rela test in the background if it is not answering (also after a reboot), then runs the Bus, State and Control in the foreground. It prints `Control test listens on 127.0.0.1:7691` when ready. The first start compiles for about half a minute. Ctrl-C twice stops the core; rela keeps running (`bin/atlas rela-stop --env test` stops it, `bin/atlas rela-status --env test` shows it).

2. **TUI 1**:

   ```sh
   bin/atlas tui --env test
   ```

3. **TUI 2**: the same command in a third terminal. Put it beside the first.

Without `--env test` both commands refuse: prod is the default and is not built yet.

## Try

In TUI 1:

| Step | Keys | What you should see |
|---|---|---|
| List | (start) | **Scenes**, sorted by code. In the status bar: `connected · opened at …`. |
| Create | `n`, type a code such as `SC-Try-01`, ↓, a title, ↓ and ←/→ for the status, `ctrl-s` | `… Sent to State; waiting until it is stored…`, then `✓ Stored by State (position N)` and the new scene opens. |
| Open | `esc` back to the list, ↑/↓, `enter` | The scene with all its fields, and how many use cases it has. |
| Change | `e`, ↓ to a field, edit (backspace, type), `ctrl-s` | `✓ Stored …` and the changed scene. |
| Delete | `d`, then `y` | `✓ Stored …` and the list without it. |
| Quit | `q` | |

Watch TUI 2 while you do this: after every change in TUI 1 its list or scene changes by itself, and its status bar says `updated by hint at …`. Every 5 seconds both TUIs also reconcile from State (`reconciled at …`), so a lost hint would only delay the change.

Also try:

- **A refusal.** Create a scene with code `XY-1`, or with an empty title. The form stays, with what you typed and a red line saying why (`id must start with SC-`, `title is required`).
- **A deleted code.** Delete a scene and create one with the same code right away. State refuses: rela keeps a deleted code reserved for a few minutes.
- **A scene with use cases.** None exist yet (UC-Atlas-02 adds them). Once one does, deleting its scene is refused with the number of use cases.
- **Losing Control.** Stop the core with Ctrl-C twice. Both TUIs say `Not connected to Control. Retrying…` and show nothing old as current. Start the core again; they come back on the page they were on.

## What is underneath

```
 TUI 1    TUI 2            clients: blocks only, JSON lines over TCP (127.0.0.1:7691)
    \      /
     Control               turns rela's description into blocks (list, item, form, confirm)
        |
   ===== Bus =====         reads only envelopes; facts and reads to State, "stored" to the
        |                  sender (acknowledgement) and to every listener (hint)
      State                checks against the description, stores in rela once per id,
        |                  answers every fact with stored (and a position) or refused
   rela test               http://127.0.0.1:7690, data in ~/.local/share/atlas/test/rela
```

Nothing on the BEAM side or in the TUI knows what a scene is. The word does not occur in their code; a test checks that. Scene comes from `rela/schema.yaml`.
