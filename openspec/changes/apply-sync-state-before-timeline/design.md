# Design

## Context

`neoment-sync--process-joined` (`neoment-sync.el:129-136`) calls `neoment-events-handle-multiple` twice per joined room: first on `timeline.events`, with `neoment-events--timeline-limited` bound to the `limited` flag, and then on `state.events`. Each call sorts only its own events by `origin_server_ts`. State handlers in `neoment-events-handle` (name, topic, avatar, canonical alias, tombstone, members) overwrite with no timestamp check, so the last call wins. See proposal.md for why that's wrong.

What I checked about the effects of the order:
- `neoment-events--timeline-limited` is read only in `neoment-events--handle-message` (thread replies count as unread). State-block events are never messages, so the flag doesn't matter for them.
- State-block `m.room.member` events add membership state messages. Messages are stored in a hash and shown ordered by `neoment-message<`, so the order of insertion doesn't change the timeline.
- `neoment-set-display-name` already ignores names older than the stored one, so display names don't depend on the order.
- `neoment-events-handle` skips an event id it has already seen (tracked rooms). If a server sends the same event in both blocks, the first copy is applied and the second is skipped. Both copies have the same content, so the result is the same.

## Goals / Non-Goals

**Goals:**
- Timeline state wins over the state block for every state type handled in `neoment-events-handle`.
- Keep the limited-timeline thread-reply unread behaviour exactly as it is.

**Non-Goals:**
- Adding timestamp guards to state handlers in general.
- Changing invited or left room processing.

## Decisions

**Swap the two calls, keeping them separate.** Call `neoment-events-handle-multiple` on `state.events` (outside the `timeline-limited` binding) and then on `timeline.events` (inside it).

Alternatives considered:
- *Merge both blocks into one sorted call.* It would order events by timestamp, but `origin_server_ts` isn't reliable for state (state events can have older or skewed timestamps), and the state block is defined by its position, not its timestamps. It would also put the state events under the `timeline-limited` binding, and the batch-id handling would then cover two blocks. Rejected.
- *Per-handler timestamp guards (like display names).* This would affect every state type and history handling too, for no gain over the order the Matrix spec already defines. Rejected as out of scope.

**Tests through `neoment-sync-process`.** Add the regression tests to `test/neoment-sync-test.el` with JSON sync bodies, like the existing `neoment-sync-limited-thread-reply-marks-unread`, so they check the real per-room order. The two existing limited / non-limited thread-reply tests stay as they are, to guard the unread logic.

## Risks / Trade-offs

- [A server sends a state block that is *newer* than the timeline (against the Matrix spec)] → The timeline value would now win. Synapse and conduwuit follow the Matrix spec here, and the next state change corrects it.
- [Membership messages from the state block are now added before timeline messages] → No visible effect: rendering sorts messages, as noted above.
