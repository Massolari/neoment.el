# Tasks

## 1. Close the window on quit

- [x] 1.1 Change `neoment-room-info-quit` in `neoment-room-info.el` to call `(quit-window t)` and update its docstring to say it closes the window. Verify `make compile lint` passes.
- [x] 1.2 Add an ERT test in `test/neoment-space-info-test.el` for the side window. In `save-window-excursion` with a single window showing a room buffer, call `neoment-room-info-open` with BESIDE, then `neoment-room-info-quit`. Assert the info buffer is dead, the frame has one window again, and the room buffer's window is selected. Verify `make test` passes.
- [x] 1.3 Add an ERT test for a window that already existed. Show a scratch buffer, call `neoment-room-info-open` without BESIDE, then `neoment-room-info-quit`. Assert the info buffer is dead, the window count is unchanged, and the window shows the scratch buffer again. Verify `make test` passes.
- [ ] 1.4 Test it by hand in Emacs: open a room, press `i`, then `q`. Confirm the right-hand window closes and focus goes back to the room.
