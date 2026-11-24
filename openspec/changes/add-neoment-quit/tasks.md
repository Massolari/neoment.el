# Tasks

## 1. Teardown helpers

- [x] 1.1 Add `neoment-ui-cancel-timer` in `neoment-rooms.el` and a `neoment--quitting` guard in `neoment-rooms-refresh`; add an ERT test that a scheduled render does not run after cancel (`make test` passes)
- [x] 1.2 Add `neoment-media-shutdown` in `neoment-media.el` (cancel popup timer, delete `neoment-mpv` process and buffer, kill popup buffer) with an ERT test using a fake process
- [x] 1.3 Add a `neoment-notify` process teardown in `neoment-notify.el` with an ERT test
- [x] 1.4 Mark event-JSON buffers opened from `neoment-room.el` with a buffer-local marker so they can be found; test that the marker is set

## 2. Command

- [x] 2.1 Implement `neoment-quit` in `neoment.el`: stop sync silently, run the helpers, kill Neoment buffers (mode list constant plus marked buffers) without prompts, show `Neoment closed`; ERT tests cover each scenario in the `session-management` delta (running sync, kept session files, unsent compose text, nothing open/logged out)
- [x] 2.2 Add `quit` to `neoment-subcommands`, a key in `neoment-menu`, and `neoment-quit` to the command list in `neoment-finishing-test.el`; verify the finishing tests pass
- [x] 2.3 Add `neoment-rooms-quit` (asks `Quit Neoment? `, default No, then `neoment-quit`) and bind `Q` in `neoment-rooms-mode-map`; ERT tests verify `y` runs the quit, `n` shows `Operation canceled` and runs nothing, and `Q` maps to the wrapper

## 3. Docs and checks

- [x] 3.1 Add `neoment-quit` to the README command table and a `Q` row (`neoment-rooms-quit`) to the room list key table, and verify both rows render
- [ ] 3.2 Run `make test` and the lint target, then run `M-x neoment-quit` in Emacs with rooms open and confirm no buffers, timers (`M-x list-timers`) or processes (`M-x list-processes`) remain

## Workflow follow-up

- Archive the change after review.
