# Design

## Context

`neoment-room-show-info` (`neoment-room.el`) calls `neoment-room-info-open` with BESIDE. That function shows the buffer with `display-buffer` and `display-buffer-in-direction` (right, 50 columns), then selects the window. Without BESIDE it uses `switch-to-buffer`. `neoment-room-info-quit` only calls `(kill-buffer (current-buffer))`. Killing a buffer replaces it in its windows but never deletes them. That is why the window stays open.

`display-buffer` records a `quit-restore` window parameter, and `switch-to-buffer` does too when `switch-to-buffer-obey-display-actions` is unset. For a window that `display-buffer-in-direction` creates, the parameter says the window is new. `quit-window` reads it: it deletes a window it created, and in an existing window it shows the previous buffer again. Either way it returns focus to the window that was selected before. `neoment-notification-settings-close` already uses `(quit-window t)`.

## Goals / Non-Goals

**Goals:**
- `q` undoes `i`: kill the info buffer and remove the side window.
- Keep `q` safe when the info buffer is in a window that already existed, or is the only window.

**Non-Goals:**
- Changing how or where `i` opens the window.
- Changing `q` in other Neoment buffers (space info, media popups and so on).

## Decisions

- **Use `(quit-window t)` in `neoment-room-info-quit`.** The window parameters Emacs already records cover every case in the spec. This also matches `neoment-notification-settings-close`.
  - *Alternative: `kill-buffer-and-window`.* Rejected. It would delete a window that existed before (the non-BESIDE path) and does not return focus to the previous window.
  - *Alternative: remember the window in a buffer-local variable and call `delete-window`.* Rejected. It repeats what `quit-restore` already does and is easy to get wrong when the window is reused.
- **Keep `neoment-room-info-open` unchanged.** Both of its display paths already set `quit-restore`.

## Risks / Trade-offs

- [The user reuses the side window for another buffer and comes back to the info buffer before pressing `q`] → `quit-window` then follows the updated `quit-restore` data and may leave the window open. That matches what Emacs does elsewhere and is acceptable.
- [Batch tests use a small terminal frame, so a 50-column split might fail] → Tests should make a known frame layout, for example with `delete-other-windows` inside `save-window-excursion`. They should check the window count and selected window, not exact sizes.
