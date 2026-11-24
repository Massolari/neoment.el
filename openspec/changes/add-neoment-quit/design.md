# Design

## Context

Sync is stopped by `neoment-sync-stop` (timer, process, generation counter). Other background state: the idle UI timer `neoment-ui--timer` (`neoment-rooms.el`), `neoment-media--popup-timer`, the `neoment-mpv` and `neoment-notify` processes, and the focus-tracking advice installed by `neoment--init`. In-flight HTTP requests are not tracked. Buffers come from several modes (`neoment-room-mode`, `-space-mode`, `-room-info-mode`, `-rooms-mode`, `-compose-mode`, `-notification-settings-mode`) plus the `*neoment-mpv*`, `*Event: ...*` and ` *neoment-popup*` buffers. See proposal.md for motivation.

## Goals / Non-Goals

**Goals:**
- One command that leaves no Neoment timer, process or buffer behind.
- Keep the saved session and the in-memory client, so `neoment` resumes quickly.

**Non-Goals:**
- Logging out or clearing caches (`neoment-logout`, `neoment-clear-cache`).
- Aborting in-flight HTTP requests; their sync callbacks are discarded by the generation check and the others are harmless.
- Unloading the Lisp features.

## Decisions

1. **Identify buffers by major mode, with explicit extras.** Kill every buffer whose `major-mode` derives from one of the Neoment modes (a list constant), plus the named buffers (`*neoment-mpv*`, the popup buffer). Alternative: match names by prefix. Rejected because room buffer names are user-facing room names; modes are reliable. Event buffers use `js-json-mode`, so they get a buffer-local marker variable when created (small change in `neoment-room.el`).
2. **Teardown helpers live in their owning files.** Add `neoment-ui-cancel-timer` (`neoment-rooms.el`), `neoment-media-shutdown` (`neoment-media.el`: popup timer, mpv process and buffer) and a notification-process teardown (`neoment-notify.el`) next to the state they own; `neoment-quit` in `neoment.el` only orchestrates.
3. **Order:** stop sync first, then cancel timers and processes, then kill buffers last, so no callback re-renders a buffer. `kill-buffer-query-functions` is bound to nil. `neoment-room--on-kill` schedules a rooms refresh via `run-at-time 0`, but `neoment-rooms-refresh` only re-renders a live rooms buffer and never creates one, so the refresh is a no-op once quit has killed it; no guard flag is needed.
4. **Keep focus-tracking advice and hooks.** They are idle and cheap, and `neoment--init` installs them once. Alternative: remove them and reset `neoment--initialized`. Rejected as extra risk for no user-visible gain.
5. **Safe when nothing runs:** each step tolerates nil timers, dead processes and missing buffers, and none needs a logged-in client.
6. **Confirmation lives in a room-list wrapper, not in `neoment-quit`.** `Q` in `neoment-rooms-mode-map` calls `neoment-rooms-quit`, which asks `y-or-n-p` (default No, `Operation canceled` on refusal) and then calls `neoment-quit`. The menu, `neoment-command` and Lisp callers stay prompt-free, matching the spec. Alternative: prompt inside `neoment-quit`. Rejected because it would break scripted use and the no-confirmation scenarios.

## Risks / Trade-offs

- [Binding `neoment-quit` directly skips the prompt] → intended; only the room-list key is guarded.
- [A late sync response re-creates the rooms buffer] → `neoment-sync-stop` bumps the generation, so the response is discarded.
- [Unsent compose text is lost] → intended; the command is explicit.
- [A buffer type added later is missed] → the mode list is one constant, and a test opens every buffer type and asserts none remain.
