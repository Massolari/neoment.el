# Proposal

## Why

For each joined room, `neoment-sync--process-joined` applies the sync `timeline` events first and the `state` block second (issue #48). In the Matrix spec, `rooms.join.<id>.state` is the room state at the *start* of the timeline. Applying it last lets older values overwrite newer state changes from the timeline. A room renamed inside a `limited` timeline keeps its old name, and a user who joined in the timeline can be removed again by an older `leave` in the state block. This happens mostly after a gap: the initial sync, or after the client was offline.

## What Changes

- Joined rooms apply `state.events` **before** `timeline.events`, so state changes in the timeline win over the state block.
- The rest of the per-room order (account data first; then summary, ephemeral and unread counts after the timeline) stays the same.
- The thread-reply unread handling for limited timelines (`neoment-events--timeline-limited`) keeps applying to timeline events only, as it does now.
- New sync tests cover the scenario from the issue (room name and membership) and check that limited-timeline unread behaviour has not changed.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `matrix-sync`: the "Joined rooms" requirement changes its processing order from `account_data, timeline, state, …` to `account_data, state, timeline, …`, and gains scenarios for timeline state overriding the state block.

## Impact

- Code: `neoment-sync.el` (`neoment-sync--process-joined`): swap the two `neoment-events-handle-multiple` calls. No change to `neoment-events.el`.
- Tests: `test/neoment-sync-test.el` gains regression tests.
- No API, configuration or dependency changes. No user-visible change except the correct room name, topic, avatar, alias, tombstone and member list after a gap.
- Out of scope: room state that disagrees *within* a single block, and history pagination (already handled by `history-keeps-current-state`).
