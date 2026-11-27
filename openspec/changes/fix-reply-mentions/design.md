# Design

## Context

- Receiving: `neoment-events--reply-to` (`neoment-events.el`) appends the replied message's mentions to the reply's in two places: the cached-entry branch (the replied message is already filled in) and the async fetch callback (for each message waiting on the placeholder). The reply's own mentions come from `neoment-events-event-to-message` (`m.mentions.user_ids`).
- Sending: `neoment-compose-message-content` builds `m.mentions` only from body mentions with a known display name. `reply-to` is just an event id, so the builder can't see who sent the replied message. `neoment-compose-send-and-close` holds the replied `neoment-message` in `neoment-compose--relation`, and that message has the sender.
- Nothing reads `neoment-message-mentions` except `neoment-storage.el`, which saves it. Desktop notifications use the server's notification and highlight counts.

## Goals / Non-Goals

**Goals:**
- A received reply's mentions are exactly its own `m.mentions.user_ids`.
- An outgoing reply follows Matrix intentional mentions by listing the replied-to sender.

**Non-Goals:**
- Adding a reader for `neoment-message-mentions`, such as highlighting or notifications.
- Rewriting mentions in messages already saved to disk.
- Putting body mentions newly added by an edit in the top-level `m.mentions`. That limitation already existed and is not addressed here.
- Saving the replied message to disk. An edit of a reply restored from storage, whose replied message is not loaded, goes out without the sender mention.

## Decisions

1. **Drop inheritance and don't substitute the sender on receipt.** Delete both `append` blocks in `neoment-events--reply-to`. The waiting list and placeholder filling stay as they are, because they still drive re-rendering and clearing unavailable replies. Alternative considered: add the replied message's sender when receiving. Rejected: Matrix v1.16 puts the sender in the replier's own `m.mentions`, so the sending client decides it. Adding it on receipt would differ from other clients, and it overrides a replier who deliberately left the mention out. It would also keep the async mutation path we are removing.

2. **New `:reply-sender` keyword on `neoment-compose-message-content` and `neoment-compose-send`.** The builder appends it to the mention list with `cl-pushnew`-style dedup after body mentions, and skips it when it is `nil` or equals `(neoment-user-id)`. The `m.mentions` block is then emitted when the merged list is non-empty. `neoment-compose-send-and-close` passes `(neoment-message-sender message)` for a `reply`. For a `replace` it passes the sender of the edited message's `replying-to` when that is loaded and not a placeholder. Because the builder wraps the content for an edit, the mention ends up only in `m.new_content`, as the Matrix spec on edits asks. Alternative considered: pass the whole message as `:reply-to`. Rejected: it changes an existing keyword's type and its tests, while a separate string keyword keeps the builder pure and easy to test.

4. **Thread replies omit `is_falling_back`.** The thread relation sets `is_falling_back: true` only when there is no `reply-to`. The Matrix spec requires it to be false or absent for a real reply, and neoment's receiver (`neoment-events.el`) ignores `m.in_reply_to` when it is true. Without this change a thread reply would ping the sender with no visible quote.

3. **Dedup order: body mentions first, then the reply sender.** The output stays deterministic for the scenarios in `specs/message-compose/spec.md`.

## Risks / Trade-offs

- [Mentions saved before the fix still include inherited ids] → Nothing reads them yet. They will be replaced when the event is processed again from sync or history. No migration needed.
- [Other users now get notified on every neoment reply] → This is what the Matrix spec intends and what other clients do. There's no opt-out, which matches Element's default. An opt-out can be added later if anyone asks for it.
- [`neoment-user-id` is nil when there is no client] → Comparing with `equal` against nil never matches a real sender, so the sender is still added. Sending without a client isn't possible anyway.
