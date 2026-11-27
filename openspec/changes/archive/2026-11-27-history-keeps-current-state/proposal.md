# Proposal

## Why

Back-pagination applies old state events to the room's current state (issue #13). `neoment-events-handle` uses `is-history` only to turn off notifications, so scrolling back can change a room's name, topic, avatar or aliases back to old values. It can also add a stale tombstone, or remove a member who left long ago and has since rejoined. That last case breaks the members table, the derived room name and the "is member" checks.

## What Changes

- State events delivered by a history page (`GET /rooms/<r>/messages`, both `chunk` and `state`) SHALL NOT change the room's current state: `name`, `topic`, `avatar_url`, `tombstone`, `aliases`, `members` and `space_rooms`.
- History state events SHALL still add their timeline entries: `Membership: …` text and the canonical-alias state message.
- Display names learned from history membership events keep the existing rule that older names never replace newer ones. Names learned from `joined_members` and `GET /profile` are current, so a history member event no longer replaces them. Live member events still do.
- Events from `/sync` (timeline and state), `GET /rooms/<r>/state` (refresh state) and account data behave as they do today.

Out of scope: `/sync` applies the `state` block after the `timeline` block, although the `state` block describes the room before the timeline. That is a separate ordering issue, tracked in #48.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `matrix-events`: adds the requirement "Paginated history keeps current state". It limits the existing state, canonical alias and membership requirements to non-history events. History events still add their timeline text. It also changes the display name requirement so that fetched names count as current.

## Impact

- `neoment-events.el`: `neoment-events-handle` and `neoment-events--handle-canonical-alias` skip state changes when `is-history` is non-nil. `neoment-events-member-message` takes `is-history` and doesn't let a history event replace a fetched display name.
- `test/neoment-events-test.el`: new regression tests for history name, topic, avatar, tombstone, aliases, membership and space child events.
- No change to the API, the user commands or the callers (`neoment-room-load-history` already passes `is-history` = t).
