# Design

## Context

See proposal.md (Why) for the bug. Current state, as found in the code:

- `neoment-room` has `name` and `aliases`. `neoment-get-room` creates rooms with `:name room-id`, so "name equals id" is the existing "unnamed" sentinel. `neoment-room-display-name` (neoment-client.el) relies on it: it uses `name` when it is not the id, otherwise heroes, otherwise members.
- `neoment-events--handle-canonical-alias` copies the first alias into `name` while `name` equals the id. The `m.room.name` branch of `neoment-events-handle` resets `name` to the id when the event's name is empty. History events (`is-history`) already leave both fields alone (issue #13), and that stays as it is.
- `neoment-invited-room` has only `name`. `neoment-events-handle-invited` overwrites it with the alias whenever an alias arrives, so the result depends on the order of the stripped events.
- `neoment-storage--room-to-json` / `-from-json` save and load `name` and `aliases`. Untracked rooms are restored from `cache.json` and then synced incrementally, so a derived alias already in the cache would not be corrected by a later sync.
- Code that reads `neoment-room-name` directly: the display-name function, the storage functions, `neoment-rooms--state-snapshot` (comparison only, so it is fine) and the `u` messages in `neoment-rooms-refresh-room-state` (user-visible, see D4). Tests set `neoment-room-name` directly to give rooms an explicit name. That keeps working.

## Goals / Non-Goals

**Goals:**
- `name` means only "explicit name", and the display name is derived from the current state every time it is needed.
- Caches written before the fix load without keeping a stale alias as an explicit name.

**Non-Goals:**
- Changing how the alias list is built (canonical first, then `alt_aliases`, ignoring empty entries). Strict Matrix name calculation uses only the canonical `alias`. Keeping the current fallback to `alt_aliases` is deliberate and preserves today's behavior.
- Migrating cached invited rooms. Invites are short-lived and are re-sent in sync. A legacy invite whose cached name is an alias will simply keep showing that alias.
- Fixing caches in which a stale alias that is no longer in `aliases` was already saved as `name` (see Risks).

## Decisions

**D1. Keep `name` as the explicit-name slot, with the room id as the "none" sentinel.**
`m.room.name` sets `name` to the non-empty name, or to the room id when the name is empty or missing (unchanged). `m.room.canonical_alias` stops touching `name`.
*Alternative:* add a new `explicit-name` slot and leave `name` as a computed cache. That would need every writer to keep the two in sync, which is exactly the problem behind this bug. *Alternative:* switch the sentinel to nil. That would touch every `(equal name room-id)` check and many tests, with no gain in behavior.

**D2. Add the alias step to `neoment-room-display-name`.**
For joined rooms the order becomes: `name` ≠ id → `(car (neoment-room-aliases room))` → heroes → members → `Empty room`. `aliases` is already filtered and ordered by `neoment-events--aliases`, so its `car` is the right alias. Every consumer (rooms list sorting, buffer names, notifications, pickers, room info) already goes through this function.

**D3. Invited rooms get an `alias` slot.**
`neoment-events-handle-invited` stores the first alias in `alias`, and stores `name` only when the name is non-empty, as today. The invited branch of `neoment-room-display-name` becomes: `name` ≠ id → `alias` → members → `Empty room`. This makes the result independent of event order. Storage writes `alias` and reads it back, treating a missing key as nil.

**D4. Use the display name in the `u` refresh messages.**
`neoment-rooms-refresh-room-state` currently formats the raw `neoment-room-name`. Under D1 that would print the room id for an alias-named room, which is a visible regression. It will use `neoment-room-display-name` instead.

**D5. Cache format: write `explicit_name`, migrate legacy `name` on load.**
- Write: `explicit_name` = `name` when it differs from the id, otherwise JSON null. Also keep writing `name` with the same value as before (the explicit name or the id), so an older neoment version reading a new cache still gets a valid name. That costs one extra field.
- Read: if the `explicit_name` key is present, `name` = its value, or the id when it is null. If the key is missing (legacy cache), `name` = the stored `name`, unless it is a member of the stored `aliases`, in which case `name` = the id.
*Alternative:* always drop a `name` that looks like an alias (`#…:…`). Rejected: it is a guess based on string shape and could discard a real explicit name. The membership test only discards names that the old code could have derived from the current aliases.
*Alternative:* bump a global cache version and throw away old caches. Rejected: that forces a full initial sync for a cosmetic issue.

## Risks / Trade-offs

- [A legacy cache whose `name` is a stale alias that is no longer in `aliases` (the bug already hit before upgrading) keeps that stale name as "explicit"] → It cannot be told apart from a real name. The user can press `u` on the room: since the refresh applies `m.room.name` state, a room with no name event remains stale. Running `neoment-clear-cache` and doing a full sync fixes it. This is documented here and accepted as rare.
- [An explicit room name that happens to equal one of its aliases is dropped when a legacy cache is migrated] → The display name then falls back to the first alias. That is the same string when it is the canonical alias, and the next `m.room.name` event restores the name. Acceptable.
- [Rooms named after an `alt_aliases` entry (no canonical alias)] → Same behavior as today. Recorded as a non-goal.

## Migration Plan

No user action is needed. The first save after upgrading writes `explicit_name`. Rolling back to an older version still reads `name` (D5), and only the original bug comes back.
