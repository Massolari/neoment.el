# Proposal

## Why

Each room list section has two ordering levels: unread rooms first, then read rooms, and the most recent activity first within each level. A room with an unread notification or highlight (a mention, a DM message, a keyword hit) is ranked the same as a room that only has unread chatter. When busier rooms get new activity, it moves down and is easy to miss. The rooms that need the user's attention should stay at the top of their section until the user reads them.

## What Changes

- Add a third ordering level. Each section that is ordered by activity becomes: rooms with notification counts (unread highlights or notifications), then other unread rooms, then read rooms. Within each level, the most recent activity comes first.
- Highlights and plain notifications share the top level. They are not ranked against each other.
- Marking a room as read with `r` clears its counts locally once the receipt succeeds. Otherwise the room would stay at the top of its section until the next sync.
- The same ordering applies wherever the activity comparator is used: the Buffers, Favorites, People, Rooms and Low priority sections, and the `neoment-pick-room` picker. Invited (by id) and Spaces (by name) keep their current ordering.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `rooms-list`: the **Ordering** requirement changes from "unread first, then most recent" to "notifications first, then unread, then read, each by most recent activity".
- `rooms-list`: the **Toggle read state** requirement adds that a successful mark-as-read clears the room's highlight and notification counts locally, so the room leaves the top group before the next sync.

## Impact

- `neoment-rooms.el`: `neoment-rooms--activity<` (used by `neoment-rooms--classify` and `neoment-pick-room`).
- `test/neoment-rooms-test.el`: new ordering tests. `neoment-rooms-unread-before-recent` still holds.
- No API, storage or dependency changes.
