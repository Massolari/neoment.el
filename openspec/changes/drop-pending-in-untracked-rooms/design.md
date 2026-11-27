# Design

## Context

`neoment-events--add-pending` (`neoment-events.el`) is the only place that writes to `neoment-room-pending-events`. It has three callers:

- the edit branch of `neoment-events--handle-message`, when `neoment-room-get-message` finds no target;
- the `m.reaction` branch of `neoment-events-handle`, likewise;
- `neoment-events--handle-redaction`, which already calls it only when `(neoment-room-is-tracked room)`. Since 6bcc683, its untracked branch redacts the kept last message, or removes it when the redaction targets its applied edit, and never keeps the event pending.

An untracked room stores no raw events (`neoment-events-handle` skips the `puthash` into `events`). Its `messages` table holds only the last non-state message, under its effective id. So `neoment-room-get-message` already finds the kept message for an edit or reaction that targets it, and fails for every other target.

`neoment-room-set-tracked` clears `pending_events` only on the way to untracked. Opening a room (`neoment-room-open` → `set-tracked t` → `neoment-room-load-more`) reloads history from the newest event back. That history includes the targets and their relations.

## Goals / Non-Goals

**Goals:**
- `pending_events` of an untracked room stays empty, whatever arrives.
- Edits, reactions and redactions of the kept last message behave exactly as today.

**Non-Goals:**
- Capping `pending_events` in tracked rooms. It is cleared when the buffer closes, and relations to messages not loaded yet are expected while scrolling history.
- Deduplicating relations that are delivered twice to an untracked room. Untracked rooms keep no event ids, which is existing behavior and not part of #19.
- Any change to the room list rendering or the cache format.

## Decisions

**Guard inside `neoment-events--add-pending`.** The function returns without storing anything when the room is untracked. The docstring says why: the target is not kept, and history delivers the event again when the room opens. All three callers already return nil (not changed) after calling it, so their results stay correct, and no future caller can bring the leak back. The tracked check in `neoment-events--handle-redaction` stays, because its untracked branch must run instead of falling through to the `null content` check. It is now redundant for storing, but it still picks the branch.
- *Alternative: check at each call site.* This repeats the condition three times, and a new caller could forget it. Rejected.

**Drop rather than cap.** The issue offers either option. A cap would still keep events whose target can never arrive in an untracked room, and it adds a tuning knob. Dropping loses nothing, because opening the room reloads history with those relations.
- *Alternative: keep pending only for the current batch* (clear it at the end of the outermost `neoment-events-handle-multiple`). This covers a relation sorted before its target in the same batch because of clock skew between servers. Edits come from the target's own sender, so they come from the same homeserver, and the skew case reduces to reactions. The room list does not show reactions, so the extra state is not worth it. Rejected.

**No change to `neoment-room-set-tracked`.** Untracked rooms no longer collect pending events, so there is nothing stale to clear when a room starts tracking.

## Risks / Trade-offs

- [A reaction from a server with a skewed clock is sorted before the kept message in the same sync, so it is dropped instead of applied] → It is invisible in the room list, and it reappears when the room is opened and history is loaded.
- [A relation dropped while untracked does not reappear if the opened history page does not reach back to its target] → In that case the relation itself is in a later page together with its target, and it goes pending in the now-tracked room as usual.
