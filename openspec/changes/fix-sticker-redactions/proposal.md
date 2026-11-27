# Proposal

## Why

Issue #20: in a tracked room, a live `m.room.redaction` whose target is an `m.sticker` does nothing. The redaction handler only recognizes `m.room.message` and `m.reaction` targets, so a redacted sticker keeps its body and keeps showing its image. Stickers are already turned into messages exactly like `m.room.message`, so they need to be redacted the same way.

## What Changes

- A redaction of a known `m.sticker` event is handled like a redaction of an `m.room.message`. The sticker's content becomes `[Redacted]` (or `[Redacted: <reason>]`), `was_redacted` is set, its attachment (the sticker image) is removed, and the room is marked as changed.
- This also covers a redaction that arrived before its sticker target: it waits as pending and is applied when the sticker arrives.
- Already working, no change: stickers that arrive already redacted (`unsigned.redacted_because`), and redactions in untracked rooms, which go by the stored message, not the event type.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `matrix-events`: the Redactions requirement says that redacting a sticker works the same as redacting a normal message.

## Impact

- `neoment-events.el`: change the target-type check in `neoment-events--handle-redaction` so it also matches `m.sticker`.
- `test/neoment-events-test.el`: add regression tests for a live sticker redaction and for a pending one.
- No API, dependency, or storage changes.
