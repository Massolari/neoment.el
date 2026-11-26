# Design

## Context

`neoment-events-handle` (`neoment-events.el`) applies each event to the room. Its `is-history` argument is non-nil only for `neoment-room-load-history` (`neoment-room.el`), which passes the `chunk` and `state` of `/messages` together. Today `is-history` only stops notifications in `neoment-events--handle-message`. The state branches (`m.room.name`, `m.room.topic`, `m.room.avatar`, `m.room.tombstone`, `m.room.canonical_alias`, `m.room.member`, `m.space.child`) write to the room no matter where the event came from.

Two things already give the client its current state without help from history:
- `/sync` gives the room's state, using `lazy_load_members` for members.
- Opening a room buffer fetches `GET /rooms/<r>/joined_members`, which fills `members` and display names.

So history never needs to fill in missing current state. It only adds older timeline entries.

Display names from membership events already go through `neoment-set-display-name`, which keeps the newest name by timestamp. History can't break them.

## Goals / Non-Goals

**Goals:**
- History events never change current room state (see specs).
- History still adds membership and alias text to the timeline.
- Keep the fix inside the event handler so that every history caller gets it.

**Non-Goals:**
- Track state by `(type, state_key)` with timestamps.
- Fix the order in which `/sync` applies its `state` and `timeline` blocks (see proposal, Out of scope).
- Change how `neoment-events-handle-invited` or the refresh-state command work.

## Decisions

**Skip state changes when `is-history` is non-nil, rather than keep a timestamp per state key.**
The issue suggests both. A timestamp per state key would need a new table on the room struct. It would also need clear rules for state from `/state` and `joined_members`, which comes without timestamps. Even with that table, it can still be wrong: an old `join` in history would add a member whose later `leave` fell in an unseen gap. Skipping is simpler, matches the "Expected" line in the issue, and is safe because current state always comes from sync or from `joined_members` (see Context).

**Change it in the handlers, not in `neoment-room-load-history`.**
Filtering out state events before handling would also drop the membership and alias messages that the timeline should show. Instead, each state branch in `neoment-events-handle` changes the room only `(unless is-history …)` and keeps building its message:
- `m.room.name`, `m.room.topic`, `m.room.avatar`, `m.room.tombstone`: skip the `setf`. Keep returning `t` so the room re-renders as before. The return value only triggers a re-render, and history callers re-render anyway.
- `m.room.member`: skip the `puthash`/`remhash` on `members`. Keep calling `neoment-events-member-message` and adding its message.
- `m.space.child`: skip `neoment-room-add-space-child`.
- `m.room.canonical_alias`: pass `is-history` to `neoment-events--handle-canonical-alias`. That function skips the `aliases` and name `setf`s and still adds the state message.

The event is still recorded in the `events` table, so dedup works the same way. If the same event later arrives through sync, sync won't apply it, but by then it isn't the current state anyway.

## Risks / Trade-offs

- [A room whose current state is only in history (for example, a state key that lazy loading left out of sync)] → Members are filled by `joined_members` when the buffer opens. Name, topic, avatar and aliases are always in the sync state of joined rooms. `neoment-rooms` "refresh state" is the manual fallback.
- [An event first seen in history and later replayed by sync with the same id is ignored by dedup] → Same as today for every event type. Sync only replays an event that is still current when it is also the newest one, and the server then sends it in the timeline before the user scrolls back that far. This is unlikely in practice and doesn't make things worse.
