# Proposal

## Why

A message that was redacted can show its old text again (issue #16). The edit handler in `neoment-events.el` never checks whether the target was redacted. So an `m.replace` that is handled after the redaction overwrites `[Redacted]` with the edit's body, while `was_redacted` stays set. This happens in normal use. A redaction arrives through sync while its target is still unknown, so it waits as pending. A history page then delivers the original and its edit. The original is handled, the pending redaction applies at once, and then the edit, which has a later timestamp, puts the content back. Redacted content is often something the author or a moderator wanted gone, so showing it again is a high-severity privacy bug.

## What Changes

- An edit (`m.replace`) whose target message is already redacted is ignored. The content, formatted content, edit data and the message's id stay as the redaction left them, and the room is not marked as changed.
- This applies wherever the edit comes from: live sync, paginated history, a pending edit released when its target arrives, or an edit embedded in `unsigned["m.relations"]["m.replace"]`.
- Because `was_redacted` is saved and loaded with the message, edits that arrive after a restart are ignored too.
- A message created from an event that already carries `unsigned.redacted_because` gets `was_redacted` set, so the guard covers it too. Such messages now render dimmed like other redacted messages and no longer count for the unread marker.
- Redacting a message that was already edited clears its edit data and restores its original id, so it is no longer shown as "[Redacted] (edited)".
- Redacting an edit that was ignored because its target is redacted no longer removes the target's `[Redacted]` placeholder.
- A regression test covers the reported order (message → redaction → edit) and the pending-redaction-then-history order.

Not changed: redacting an *edit event* still removes the edited message entry, edits to messages that are not redacted still work as before, and the redaction text is the same.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `matrix-events`: the **Edits** requirement gains the rule that edits to a redacted message are ignored.
- `matrix-events`: the **Redactions** requirement clears applied edits on redaction and keeps the placeholder when an ignored edit is redacted.

## Impact

- Code: `neoment-events.el`: a guard in the edit branch of `neoment-events--handle-message`, the redacted flag in `neoment-events-event-to-message`, and the message and edit branches of `neoment-events--handle-redaction`. No API or storage format changes. UI: messages that arrive already redacted render dimmed, and redacted messages no longer show "(edited)".
- Tests: `test/neoment-events-test.el` (edits and redactions section).
- Spec: `openspec/specs/matrix-events/spec.md` (Edits requirement).
