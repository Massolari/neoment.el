# Proposal

## Why

Neoment applies every `m.replace` edit, whoever sent it, so any room member can rewrite anyone else's message (issue #15, confirmed: an edit from `@mallory:s` to a message from `@alice:s` changes its content to `"hacked"`). The Matrix spec requires clients to ignore a replacement whose `sender` differs from the original event's sender, and to ignore replacements of state events. This is a spoofing problem with high severity, and the fix is a small guard.

## What Changes

- An edit SHALL be applied only when its `sender` equals the target message's sender. Otherwise it is ignored and the target is left unchanged.
- An edit whose target is a state message (membership, topic, name, and so on) SHALL be ignored.
- Pending edits (edits that arrive before their target) get the same checks when the target arrives. A rejected edit is dropped, not kept pending.
- Edits embedded in `unsigned["m.relations"]["m.replace"]` get the same checks.
- When a replied-to event is fetched, its bundled `m.replace` replacement SHALL be used only when the replacement's sender matches the event's sender. Otherwise the original event is shown. Today the replacement is used as-is, including its `sender`, so a foreign replacement would also change who the reply quote seems to come from.
- Redacting an edit event SHALL remove the edited message only when the edit's sender matches the message's sender. Today, redacting any edit removes its target from the room. Once foreign edits are ignored, this would still let any member delete another member's message by sending an edit and then redacting it. Issue #15 does not mention this case. It is included because it is the same spoofing vector.

Out of scope: other `m.replace` validity rules from the Matrix spec (matching `type`, no `state_key`, the target not being an edit itself), and edits of encrypted events.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `matrix-events`: a new **Edit validation** requirement ignores edits from another sender and edits of state messages (the existing **Edits** requirement is unchanged), the **Replies** requirement uses a fetched event's bundled replacement only when the senders match, and the **Redactions** requirement removes an edited message only for a redacted edit from the message's own sender.

## Impact

- `neoment-events.el`: the edit branch of `neoment-events--handle-message`, the edit branch of `neoment-events--handle-redaction`, and `neoment-events--event-message-fields` (used when a replied-to event is fetched).
- `test/neoment-events-test.el`: new cases next to `neoment-events-edits` and the reply-fetch test.
- No API, dependency or configuration changes. Edits from the original sender behave as before.
