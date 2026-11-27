# Proposal

## Why

The room list's plain unread state (the `•` badge, and the middle level of the room ordering) shows rooms as unread after the user has read them (issue #7). It has three causes. The rule compares event ids for equality instead of their order in the timeline. The user's own messages count as unread activity. Thread replies count too, even though neoment never treats a thread as read.

## What Changes

- The unread check uses a new *unread activity* instead of the room's last activity. Unread activity is the newest main-timeline message or sticker (not an edit) sent by someone other than the user. Thread replies and the user's own messages are left out.
- Last activity stays as it is. Thread replies and the user's own messages still move the room up the list and update its relative time.
- A room is read when its read receipt or its `m.fully_read` marker is **at or after** the unread activity, not only when one of them points at that exact event. Order comes from the timestamp of the marker's event when that event is loaded. Otherwise, for the receipt only, it comes from the receipt's own `ts`.
- The room cache keeps unread activity. A cache written before this change falls back to last activity, which gives the same result as today until new activity arrives.
- New tests in `test/neoment-rooms-test.el` and `test/neoment-events-test.el` cover each case in the issue.

Out of scope: tracking threaded receipts, sending receipts from thread buffers, and any per-thread unread indicator. Thread replies alone no longer set the `•` badge. The server's notification and highlight counts still flag them.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `matrix-events`: the "Unread rule" compares by order and uses unread activity. "Ordering and last activity" defines unread activity and when it updates.
- `session-management`: the "Compact room cache" holds unread activity and `fully_read`, and an older cache falls back to last activity.

## Impact

- `neoment-client.el`: new room field for unread activity, its setter, and a rewritten `neoment-room-unread-p` with an order comparison.
- `neoment-events.el`: `neoment-events--handle-message` updates unread activity for non-thread messages from other users.
- `neoment-storage.el`: saves and restores `unread_activity`, with a fallback for older caches.
- Callers of `neoment-room-unread-p` are unchanged: the room list's badge, sorting and `r` action, `neoment-room-mark-read`, and the automatic read marking. They still send read markers on the last activity event, which is at or after the unread activity.
- No change to server-provided counts, desktop notifications or the network protocol.
