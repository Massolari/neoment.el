# Proposal

## Why

Neoment names its buffers with Neovim-style pseudo-URIs such as `neoment://room/!abc:server/Space/dev`. These look odd in Emacs buffer lists and in `switch-to-buffer`. The Matrix IDs in them are noise, and they don't follow the Emacs convention that buffers which don't visit files get earmuffs (`*name*`). Neoment already uses that convention elsewhere (`*neoment-player*`, `*neoment-image: <file>*`), so the `neoment://` names are also inconsistent within the package.

## What Changes

- Room, thread, room-info, space and compose buffers get Emacs-style names of the form `*neoment-<kind>: <label>*`, where the label is human-readable:
  - Room: `*neoment-room: <Space/Name>*` (was `neoment://room/<room_id>/<Space/Name>`)
  - Thread: `*neoment-thread: <author> in <room>*` (was `neoment://thread/<root_id>/sender/<author>`)
  - Room info: `*neoment-room-info: <Space/Name>*` (was `neoment://room/info/<id>/<Space/Name>`)
  - Space: `*neoment-space: <name>*` (was `neoment://space/<id>/<name>`)
  - Compose: `*neoment-compose: <description>*`, e.g. `*neoment-compose: Replying to Alice*` (was `neoment://compose/<description>`)
- The hidden rooms list buffer becomes ` *neoment-rooms*` (was ` neoment://rooms`). It keeps the leading space, so it stays hidden from buffer switching.
- Buffer names no longer contain Matrix room, space or event IDs. If two buffers would get the same name, Emacs' usual `<2>` suffix tells them apart. Buffers are already found through buffer-local state, not by name, so this does not affect lookup.
- **BREAKING** (cosmetic): anyone whose own configuration matches buffers by the `neoment://` prefix (for example, `display-buffer-alist` rules) has to update the pattern.

Out of scope: renaming open buffers when a room is renamed, and the existing `*Event: <id>*`, `*Neoment notification settings*` and image/player buffer names, which already follow the earmuffs convention.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `room-timeline`: the "Room buffer identity" requirement changes the room buffer name.
- `message-actions`: the "Threads" requirement changes the thread buffer name.
- `room-info`: the "Room info buffer" requirement changes the info buffer name.
- `spaces`: the "Space buffer" requirement changes the space buffer name.
- `message-compose`: the "Compose buffer naming" requirement changes the compose buffer prefix.
- `rooms-list`: the "Rooms list window" requirement changes the hidden buffer name.

## Impact

- Code: `neoment-room.el` (`neoment-room-buffer-name`, `neoment-room-thread-buffer-name` and its caller), `neoment-room-info.el` (`neoment-room-info-buffer-name`), `neoment-space.el` (`neoment-space-buffer-name`), `neoment-compose.el` (`neoment-compose-buffer-name`), `neoment-rooms.el` (`neoment-rooms-buffer-name`).
- Tests that assert the exact names: `test/neoment-room-test.el`, `test/neoment-compose-test.el`, `test/neoment-actions-test.el`, `test/neoment-media-test.el`, `test/neoment-space-info-test.el`.
- No changes to the Matrix API or dependencies.
