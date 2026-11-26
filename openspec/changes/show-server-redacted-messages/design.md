# Design

## Context

See proposal.md (Why). The relevant code is all in `neoment-events.el`:

- `neoment-events--handle-message` starts its `cond` with `((not (stringp (alist-get 'body content))) nil)`. A redacted event's `content` is `{}`, which parses to nil, so the event is dropped before any other branch runs.
- `neoment-events-event-to-message` already turns `unsigned.redacted_because` into `[Redacted]` / `[Redacted by <name>]`, but it does not set `was-redacted` and it can still build an attachment from `content`.
- The reply fetch callback in `neoment-events--reply-to` only accepts `(and data (alist-get 'content data))`. An empty `content` falls through to the "unavailable" branch, which clears `replying-to` on every waiting reply.
- `neoment-events--fill-message` copies the displayed fields from the fetched message into the placeholder but not `was-redacted`.
- The raw event stored in `neoment-room-events` keeps its empty `content`. The live redaction handler already treats `(null (alist-get 'content target))` as "already redacted", so a later `m.room.redaction` of a server-redacted message is ignored without any change.

## Goals / Non-Goals

**Goals:**
- A message renders the same way (text, dimmed header, `was_redacted`) whether its redaction was seen live or arrived already applied.
- One predicate decides "this event is redacted", shared by the timeline path and the reply-fetch path.

**Non-Goals:**
- Unifying the two text formats. Live redaction shows `[Redacted]` / `[Redacted: <reason>]`, while server-redacted messages show `[Redacted]` / `[Redacted by <name>]`. Both formats are in the spec today, and changing either one is a separate, user-visible decision.
- Hiding redacted edits or redacted thread replies. In current room versions, redaction strips `m.relates_to`, so the client cannot tell them apart from ordinary messages (see Risks).

## Decisions

1. **Add a small predicate `neoment-events--redacted-p (event)`** that returns non-nil when `unsigned.redacted_because` is present. The guard in `handle-message` becomes "no string body **and** not redacted → ignore". The redacted check sits before the body check, as the issue requests.
   - *Alternative:* add a separate `cond` branch for redacted events ahead of the guard. Rejected because it would duplicate the add-message, last-activity and notification steps of the existing `t` branch. Once the guard lets a redacted event through, it falls naturally into the `t` branch. It cannot enter the edit branch, because its `m.relates_to` was stripped.

2. **`event-to-message` sets `:was-redacted t` and no attachment when the event is redacted.** This keeps one constructor for all paths: timeline, history and reply fetch. It matches what the live redaction handler does to an existing message. The mentions list comes from `content`, so it is already empty for a stripped event and needs no special case.

3. **Reply fetch accepts `(or (alist-get 'content data) (neoment-events--redacted-p data))`**, and `fill-message` copies `was-redacted`. The replied message then carries the redacted text and can be styled like any redacted message. The existing reply prefix rendering (`┃ <sender>:` / `┃ <line>`) needs no change.
   - *Alternative:* render a fixed "replied message was deleted" string. Rejected because it would add a new UI string and diverge from the redacted text used in the timeline.

4. **Redacted messages are never notification text.** `neoment-notify-add-candidate` and the stored-message fallback skip messages marked `was_redacted`. Otherwise, when one sync brings a real message that raises the count and a later already-redacted one, the notification would read `[Redacted…]` instead of the real text.
5. **A server-redacted message is not activity.** The `t` branch skips `last_activity` and `unread_activity` for it, so a moderator clean-up neither marks the room unread nor moves it up the room list. This matches the room buffer, whose unread marker already skips redacted messages.
6. **The reply fetch ignores a bundled edit on a redacted event**, so the quote never shows pre-redaction text that the timeline hides.

## Risks / Trade-offs

- [Redacted edits and redacted thread replies now appear as standalone `[Redacted]` messages in the main timeline, because their relation was stripped by the server.] → This matches what other clients that show redactions do, and it is strictly better than the current behaviour, where a redacted *normal* message vanishes. If it proves noisy, a later change could hide redacted events whose `redacted_because` arrives together with a known edit relation in `unsigned`.
- [Stored rooms (neoment-storage) saved before this change lack these messages.] → No migration is needed. They reappear the next time history or sync delivers the events.

## Migration Plan

None. This is a pure client-side behaviour fix with no storage or API change. To roll back, revert the commit.
