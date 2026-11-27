# Proposal

## Why

Issue #27: an incoming reply inherits the replied message's `m.mentions.user_ids` instead of its sender. So replying to a message that mentioned you counts as mentioning you (false positive), and a reply to *your* message doesn't count as one (false negative). The Matrix spec (Rich replies, "Mentioning the replied to user", changed in v1.16) says clients SHOULD no longer propagate mentioned users from the replied-to event, and MAY include the replied-to event's sender in the reply's own `m.mentions`. Receivers then trust that list alone. Neoment does neither side correctly. It merges mentions when receiving, and it never adds the replied-to sender when sending.

## What Changes

- **Receiving**: a reply's mentions SHALL come only from its own `m.mentions.user_ids`. The replied message's mentions are no longer merged in, either when the replied event is already known or after it is fetched asynchronously.
- **Sending**: when the user replies to a message from another user, that sender's user id SHALL be added to the outgoing `m.mentions.user_ids`, without duplicates. Replying to your own message adds nothing. A reply with no other mentions gets `m.mentions` holding only the replied-to sender.
- **Thread replies**: a thread message that replies to an event SHALL omit `is_falling_back`, since a real reply is not a fallback. Otherwise every client, neoment included, would drop the reply relation while the new mention still pinged the sender.
- **Edits of a reply**: the replied-to sender SHALL stay in `m.new_content.m.mentions` when the replied message is loaded, so the replacement content keeps the full mention set. It is not added to the top-level `m.mentions`, because the edit does not newly mention anyone.
- Thread messages without a reply and plain messages keep today's `m.mentions` behavior.

Decision on the issue's open question: we chose "rely only on the reply's own `m.mentions`" over "add the replied message's sender when receiving". Adding the sender on receipt would override the replier's explicit choice and disagree with other Matrix clients. Making neoment's own replies populate `m.mentions` keeps outgoing replies correct.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `matrix-events`: the "Replies" requirement no longer adds the replied message's mentions to the reply's mentions.
- `message-compose`: the "Reply and thread relations" requirement adds the replied-to sender (if not the current user) to `m.mentions.user_ids`, omits `is_falling_back` on thread replies, and keeps the sender in `m.new_content.m.mentions` when editing a reply.

## Impact

- `neoment-events.el`: `neoment-events--reply-to` (cached-entry branch and async fetch callback) stops appending the replied message's mentions.
- `neoment-compose.el`: `neoment-compose-message-content` / `neoment-compose-send` / `neoment-compose-send-and-close` pass the replied-to sender (for replies, and for edits of a loaded reply) so the content builder can add it to `m.mentions`. The thread relation omits `is_falling_back` when it has `m.in_reply_to`.
- Tests: `test/neoment-events-test.el`, `test/neoment-compose-test.el`.
- Visible effect: other users' clients will now notify the replied-to user when they get a neoment reply. Nothing in neoment reads `neoment-message-mentions` today (notifications use server counts), so the change has no visible effect inside neoment's own UI.
