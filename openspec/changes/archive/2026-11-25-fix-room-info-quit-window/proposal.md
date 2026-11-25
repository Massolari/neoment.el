# Proposal

## Why

Pressing `i` in a room opens the room info buffer in a new 50-column window to the right. Pressing `q` there kills the buffer, but the window stays open and shows some other buffer, so the user has to close it by hand. `q` should undo what `i` did.

## What Changes

- `q` in the room info buffer (`neoment-room-info-quit`) closes the window that `i` created and kills the buffer, then returns focus to the window that was selected before.
- When the info buffer was shown in a window that already existed (for example, `neoment-room-info-open` without BESIDE, which uses `switch-to-buffer`), `q` kills the buffer and that window goes back to the buffer it showed before. It is not deleted.
- The `q` behaviour moves out of the "Avatar actions" requirement into its own requirement.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `room-info`: adds a "Close room info" requirement saying how `q` treats the window, and removes the outdated "`q` kills the buffer" sentence from "Avatar actions".

## Impact

- Code: `neoment-room-info-quit` in `neoment-room-info.el`.
- Tests: `test/neoment-space-info-test.el` gains a test for quitting from a side window and from a reused window.
- No API, storage, or server changes.
- The unarchived `emacs-style-buffer-names` change also modifies `room-info` ("Room info buffer"). This change leaves that requirement alone so the two deltas do not conflict.
