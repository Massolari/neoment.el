# Proposal

## Why

A message that was redacted can show its old text again (issue #16). The edit handler in `neoment-events.el` never checks whether the target was redacted. So an `m.replace` that is handled after the redaction overwrites `[Redacted]` with the edit's body, while `was_redacted` stays set. This happens in normal use. A redaction arrives through sync while its target is still unknown, so it waits as pending. A history page then delivers the original and its edit. The original is handled, the pending redaction applies at once, and then the edit, which has a later timestamp, puts the content back. Redacted content is often something the author or a moderator wanted gone, so showing it again is a high-severity privacy bug.

## What Changes

- An edit (`m.replace`) whose target message is already redacted is ignored. The content, formatted content, edit data and the message's id stay as the redaction left them, and the room is not marked as changed.
- This applies wherever the edit comes from: live sync, paginated history, a pending edit released when its target arrives, or an edit embedded in `unsigned["m.relations"]["m.replace"]`.
- Because `was_redacted` is saved and loaded with the message, edits that arrive after a restart are ignored too.
- A regression test covers the reported order (message → redaction → edit) and the pending-redaction-then-history order.

Not changed: redacting an *edit event* still removes the edited message entry, edits to messages that are not redacted still work as before, and the redaction text is the same.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `matrix-events`: the **Edits** requirement gains the rule that edits to a redacted message are ignored.

## Impact

- Code: the edit branch of `neoment-events--handle-message` in `neoment-events.el`. It is one extra guard. No API, storage or UI changes.
- Tests: `test/neoment-events-test.el` (edits and redactions section).
- Spec: `openspec/specs/matrix-events/spec.md` (Edits requirement).
