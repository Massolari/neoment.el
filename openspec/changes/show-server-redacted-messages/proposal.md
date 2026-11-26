# Proposal

## Why

A message redacted on the server reaches the client with an empty `content` and `unsigned.redacted_because`. The body guard in `neoment-events--handle-message` drops any message without a string `content.body`, so these events never become messages (issue #17). The result depends on the path the message arrived by. A redaction seen live shows `[Redacted]`, but the same message seen through history or initial sync disappears. The existing `[Redacted]` / `[Redacted by <name>]` branch in `neoment-events-event-to-message` is dead code for timeline events. Replies to a redacted message also lose their quote, because the reply fetch treats an empty `content` as "event unavailable".

## What Changes

- An `m.room.message` / `m.sticker` event that carries `unsigned.redacted_because` SHALL become a message even when it has no `content.body`. It shows `[Redacted]`, or `[Redacted by <name>]` when the redactor is not the author, as the spec already describes.
- Such a message SHALL be marked `was_redacted`, as a live redaction is. Its header is then dimmed, and it does not count as a visible message for the "New messages" separator.
- When the asynchronously fetched replied event is a redacted event, the reply SHALL show the redacted quote (`┃ <sender>:` / `┃ [Redacted…]`) instead of dropping it. The filled placeholder SHALL also carry `was_redacted`.
- Events without `content.body` and without `redacted_because` are still ignored, so behaviour for malformed or unknown events does not change.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `matrix-events`: The "Message content" requirement gains an exception to the "events without `content.body` SHALL be ignored" rule for redacted events. Two requirements are added: "Server-redacted messages" (the message is kept and marked `was_redacted` with no attachment) and "Replies to redacted messages" (a fetched replied event that is redacted still fills the reply quote).

## Impact

- Code: `neoment-events.el`, specifically `neoment-events--handle-message` (the body guard), `neoment-events-event-to-message` (set `was-redacted`), `neoment-events--reply-to` (the fetch callback's "unavailable" check) and `neoment-events--fill-message` (copy `was-redacted`).
- Tests: `test/neoment-events-test.el` (message content and async reply cases).
- No API, storage format or dependency changes. `was_redacted` is already persisted by `neoment-storage.el`.
