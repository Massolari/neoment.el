# Tasks

## 1. Room and thread buffers

- [x] 1.1 Change `neoment-room-buffer-name` in `neoment-room.el` to return `*neoment-room: <Space/Name>*`, and update the assertions in `test/neoment-room-test.el` (lines ~575 and ~750). Verify with `make test`.
- [x] 1.2 Change `neoment-room-thread-buffer-name` to take `(room-id author)` and return `*neoment-thread: <author> in <room display name>*`, and pass `room-id` from `neoment-room-open-thread-buffer`. Update `test/neoment-room-test.el` (~576) and `test/neoment-actions-test.el` (~133, expect `*neoment-thread: Alice in dev*`). Verify with `make test`.
- [x] 1.3 Add a test that opens two rooms with the same display name and checks that they get distinct buffers (`*neoment-room: dev*` and `*neoment-room: dev*<2>`) and that reopening each room finds its own buffer. Verify with `make test`.

## 2. Room info and space buffers

- [x] 2.1 Change `neoment-room-info-buffer-name` in `neoment-room-info.el` to return `*neoment-room-info: <Space/Name>*`, and update `test/neoment-space-info-test.el` (~198). Verify with `make test`.
- [x] 2.2 Change `neoment-space-buffer-name` in `neoment-space.el` to return `*neoment-space: <name>*`, and update `test/neoment-space-info-test.el` (~97, expect `*neoment-space: Neovim Brasil*`). Verify with `make test`.

## 3. Compose buffers

- [x] 3.1 Change `neoment-compose-buffer-name` in `neoment-compose.el` to wrap the description and any attachment suffix in `*neoment-compose: …*`. Update `test/neoment-compose-test.el` (lines 32–42), `test/neoment-actions-test.el` (~121), and `test/neoment-media-test.el` (~795, plus the `string-prefix-p "neoment://compose"` cleanup at ~805, which becomes `"*neoment-compose:"`). Verify with `make test`.

## 4. Rooms list buffer

- [x] 4.1 Change `neoment-rooms-buffer-name` in `neoment-rooms.el` to ` *neoment-rooms*` (keeping the leading space) and update its docstring. Verify with `make test` (`test/neoment-quit-test.el` reads the constant) and by checking that the list does not show up in `switch-to-buffer` completion.

## 5. Integration checks

- [x] 5.1 Run `grep -rn 'neoment://' --include='*.el' --include='*.md' . ':!openspec/changes'` and confirm that no matches remain outside archived changes.
- [x] 5.2 Run `make compile lint test` and confirm that all three pass with no byte-compile warnings.

## Workflow follow-up

- Archive the change once it is implemented and reviewed, which syncs the six delta specs into `openspec/specs/`.
