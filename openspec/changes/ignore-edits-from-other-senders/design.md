# Design

## Context

See proposal.md (Why) for motivation and `specs/matrix-events/spec.md` for the required behavior. The current code paths involved:

- `neoment-events--handle-message` handles edits in its `m.replace` branch. It looks up the target with `neoment-room-get-message`. If the target is unknown, the edit is added as pending. Otherwise, if the edit is newer than the last applied one, it overwrites content, formatted content, `edit-data` and id. The target's `sender` is never touched, so it always holds the original author, even after several edits.
- Pending events are replayed by `neoment-events-handle-multiple`, which calls `remhash` on the pending list *before* it handles those events again. Embedded edits (`unsigned.m.relations.m.replace`) are sent back through `neoment-events-handle`. Both paths therefore reach the same `m.replace` branch.
- State messages are `neoment-message` structs with `is-state` set to `t` (`neoment-events--state-message`). They live in the same message table, so an edit can find one as its target.
- `neoment-events--event-message-fields` builds the replied-to message from a fetched event, using the bundled `m.replace` event in place of the original when there is one. `neoment-events--fill-message` then copies `sender` from it.
- `neoment-events--handle-redaction`, when the redacted event is an `m.replace`, removes the *target* message from `neoment-room-messages`, without any sender check.
- Sending an edit (`neoment-compose.el`) builds the event content only. Own edits come back through sync like any other event, with a real `sender`.

## Goals / Non-Goals

**Goals:**
- One guard in the edit branch that covers live, pending and embedded edits.
- The same sender rule wherever an `m.replace` is trusted: when an edit is applied, when a replied-to event is fetched, and when an edit is redacted.

**Non-Goals:**
- Showing rejected edits to the user in any way, or logging them.
- The other `m.replace` validity rules (type match, `state_key`, edits of edits) and encrypted events.

## Decisions

1. **Add the guard as a new `cond` clause in the edit branch, right after the `(null target)` clause and before the timestamp check.** The clause returns nil (room unchanged) when the target is a state message or when the senders differ. Putting it before the timestamp check means a rejected edit never takes part in the newer-or-older comparison.
   - Alternative: filter in `neoment-events-handle` before dispatch. Rejected: the target is not known there, and the pending path would need its own copy of the check.

2. **Compare senders with a helper that requires both to be strings**, for example `neoment-events--same-sender-p (a b)` → `(and (stringp a) (equal a b))`. Plain `equal` would accept an edit with no `sender` against a target whose sender is also nil. Real events always have a sender, so this only closes an edge case. The helper is reused by the reply and redaction paths.

3. **Pending edits need no extra code.** `neoment-events-handle-multiple` already removes the pending list before replaying it, so an edit rejected on replay is simply dropped, which is what the spec asks for. A test pins this behavior so a later refactor of the pending logic cannot silently change it.

4. **Reply fetch: use the bundled replacement only when its sender matches the event's sender.** Otherwise call `neoment-events-event-to-message` on the original event. This is a one-line condition in `neoment-events--event-message-fields`.

5. **Redaction of an edit: remove the target message only when the redacted edit's sender matches the target message's sender.** In every other case, leave the message alone. The edit event's content is still cleared as today, so it is not redacted twice. Return nil when nothing visible changed, so the room is not re-rendered for nothing.
   - Alternative: change redaction of an edit to revert to the previous content instead of removing the message. That would be better behavior, but it changes the existing spec for same-sender edits and is out of scope for this security fix.

## Risks / Trade-offs

- [The homeserver bundles a foreign replacement in `unsigned`, and the user sees the unedited message while other clients show the edit] → This is the behavior the Matrix spec requires, and compliant clients (for example Element) do the same.
- [An edit applied before this fix stays applied in a running session] → The state is in memory only. History is rebuilt from events when a room buffer is reopened, so the fix applies then.
- [Two events with the same sender but different device or display name] → Matching is on the user id (`sender`) only, as the Matrix spec requires. Display names are not involved.
