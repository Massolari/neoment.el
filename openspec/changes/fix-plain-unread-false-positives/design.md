# Design

## Context

See proposal.md (Why). Relevant current state:

- `neoment-room-last-activity` (`neoment-client.el`) is a plist `(:timestamp :event-id :age)`. `neoment-room-set-last-activity` keeps it monotonic, and `neoment-events--handle-message` updates it for every new message or sticker with a body (edits excluded), whatever the sender or thread. The room list uses it for sort order, relative time and the "badge needs last activity" check. `neoment-room-mark-read` and the list's `r` use its event id as the read-marker target.
- `neoment-room-unread-p` is the only place that decides the plain unread state. It compares the last activity id with `read-receipt :event-id` and `fully-read` for equality.
- An untracked room keeps only its newest non-state message (`neoment-room-add-message`). The raw `events` table is filled only for tracked rooms. So a marker's event is often not loaded, and the unread rule cannot be computed by scanning messages.
- The read receipt is a plist `(:event-id :ts :is-local)`. Server receipts carry the `ts` the receipt was sent. Local receipts (from `neoment-api-set-read-markers`) use the target message's timestamp. `fully-read` is a bare event id.

## Goals / Non-Goals

**Goals:**
- Fix the three false-positive cases in issue #7 without changing sort order, relative times, badges for counts, or what neoment sends to the server.
- Keep the rule cheap: it runs for every room on every room-list render.

**Non-Goals:**
- Threaded receipts, per-thread read state, or thread unread indicators (the user chose to exclude thread replies instead).
- Changing which event `neoment-room-mark-read` or `r` targets.

## Decisions

### 1. A separate `unread-activity` field instead of filtering `last-activity`

Add a room slot `unread-activity` with the same plist shape as `last-activity`, updated by a setter that applies the same monotonic rule (`neoment-room-set-unread-activity`, sharing the comparison with `neoment-room-set-last-activity`). `neoment-events--handle-message` calls it alongside the last-activity update, but only when the message has no `thread-root-id` and its sender is not `(neoment-user-id)`.

*Alternative:* Exclude own messages and thread replies from `last-activity` itself. Rejected because the room would no longer move up the list when the user posts or a thread gets a reply, and the relative time would go stale. *Alternative:* Derive unread activity on demand from stored messages. Rejected because untracked rooms only hold the newest message, so the answer would be missing exactly when the newest message is the user's own or a thread reply.

### 2. Order comparison through a marker timestamp

`neoment-room-unread-p` becomes:

```
unread  = (eq unread t)
       or (and unread-activity
               (not (marker-covers-p receipt-id receipt-ts))
               (not (marker-covers-p fully-read nil)))
marker-covers-p(id, fallback-ts):
  id = activity id                         -> t
  ts := timestamp of the event id if loaded, else fallback-ts
  ts and ts >= activity :timestamp          -> t
```

"Loaded" means `neoment-room-find-message` returns a message (which also matches edits by original id), or the raw `events` table holds the id with an `origin_server_ts`. The second lookup catches state events that other clients put receipts on.

*Why receipt `ts` only as fallback:* it is the time the receipt was sent, not the event's position, and it comes from the user's homeserver clock while `origin_server_ts` may come from another server. A loaded event's own timestamp is exact, so it wins. `fully_read` has no timestamp, so an unloaded `fully_read` event proves nothing and does not count.

*Alternative:* Compare timeline positions (index in sorted messages). Rejected because both events must be loaded, which is rarely true for untracked rooms, and timestamps already define the sort order (`neoment-message<`).

### 3. Leave read-marking callers alone

`neoment-room-mark-read` and `r` keep targeting `last-activity :event-id`. That event is at or after unread activity, and the local receipt they set uses its message timestamp, so the room becomes read immediately. When the newest activity is the user's own message or a thread reply, the room is already read, so no receipt is sent. This matches the Matrix rule that your own events are implicitly read. The compose path that sets `fully-read` to a sent event stays and is now redundant but harmless.

### 4. Cache

`neoment-storage` writes `unread_activity` next to `last_activity` with the same plist↔alist helpers. On restore, a missing or null `unread_activity` falls back to `last_activity`. That reproduces today's behavior for a room until new activity arrives, instead of silently marking every cached room read.

## Risks / Trade-offs

- [Clock skew between homeservers makes a fallback receipt `ts` look later than an unloaded-receipt room's activity] → Used only when the receipt's event isn't loaded, and a receipt `ts` is normally well after the event it acknowledges. A wrong "read" is limited to messages that arrived within the skew window.
- [Two events share one millisecond, and the receipt is on the earlier one] → `>=` treats the room as read. This is rare and harmless. The server counts still flag mentions.
- [A thread reply from another user no longer sets `•` on its own] → This was the user's choice. The server notification count still shows the room in the notifications group when the push rules notify.
- [An older cache's fallback keeps a false positive whose last activity was an own message or a thread reply] → It clears the next time the room is opened or new main-timeline activity arrives.

## Migration Plan

No migration step. The new cache key is additive, and an older neoment reading a newer cache ignores the unknown key. Rollback is a plain revert.
