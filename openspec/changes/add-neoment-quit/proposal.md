# Proposal

## Why

Neoment has no way to shut itself down. To stop using it without logging out, the user must run `neoment-sync-stop` and then kill every Neoment buffer by hand (rooms list, rooms, spaces, room info, compose, settings, event and mpv buffers). Logging out is not an option because it deletes the saved session.

## What Changes

- Add an interactive command `neoment-quit` that stops all background activity and kills all Neoment buffers, while keeping the saved session so the next `neoment` restores it.
- Stop the sync loop (silently), cancel the UI render and media popup timers, and delete the Neoment helper processes (mpv playback, desktop notifications).
- Kill every Neoment buffer without confirmation prompts, including compose buffers with unsent text.
- Expose the command in the `neoment-menu` transient, the `neoment-command` subcommands (`quit`) and the README command table.
- Show `Neoment closed` when done.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-management`: adds requirements for quitting Neoment without ending the session.

## Impact

- Code: `neoment.el` (command, menu, subcommand), small teardown helpers in `neoment-rooms.el` (UI timer), `neoment-media.el` (popup timer, mpv process), `neoment-notify.el` (notification process).
- Docs: `README.md` command table.
- Tests: new ERT tests; `neoment-finishing-test.el` command list.
- No new dependencies, no change to saved data.
