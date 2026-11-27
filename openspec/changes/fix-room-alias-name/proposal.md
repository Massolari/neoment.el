# Proposal

## Why

Issue #22: a joined room without an `m.room.name` is named by copying its first alias into `name` (`neoment-events.el`, `neoment-events--handle-canonical-alias`). The copy happens only while `name` equals the room id, so the room keeps showing an outdated alias. Specifically:
- after `#old:s` → `#new:s` the room stays `#old:s`
- after the aliases are removed, the removed alias stays
- an empty `m.room.name` resets the name to the room id even when the room has an alias

Once the alias is written into `name`, nothing can tell it apart from a name someone actually set.

## What Changes

- `name` holds only the explicit name from `m.room.name`. It falls back to the room id when no name is set or the name is empty, the same sentinel as today. `m.room.canonical_alias` no longer writes to `name`, only to `aliases`.
- The room display name is derived each time it is needed, in this order: explicit name → first alias (canonical, then the first `alt_aliases`) → heroes → other members → `Empty room`.
- Invited rooms follow the same order. The stripped `m.room.canonical_alias` goes into its own `alias` slot instead of overwriting `name`, so whichever order the stripped events arrive in, an explicit `m.room.name` always wins.
- Cache: the compact room cache stores the explicit name under a new key `explicit_name`. Caches from earlier versions only have `name`, which may hold a derived alias. On load, a legacy `name` that equals one of the cached aliases is treated as "no explicit name".
- The `u` (refresh room state) messages use the room's display name instead of the raw `name`, so a room named after its alias does not show up as its room id.

## Capabilities

### New Capabilities

None.

### Modified Capabilities
- `matrix-events`: "Canonical alias handling" no longer names the room. "Room account data and state events" says how an empty `m.room.name` is handled. "Derived room rules" adds the alias step to the display-name order.
- `matrix-sync`: "Invited rooms" keeps the alias separate from the name, and an explicit name wins. "Room name from heroes" applies only when the room has neither a name nor an alias.
- `session-management`: "Compact room cache" stores `explicit_name` and migrates a legacy alias-derived `name`.

## Impact

- `neoment-events.el`: the `m.room.name` branch of `neoment-events-handle`, `neoment-events--handle-canonical-alias`, and `neoment-events-handle-invited`.
- `neoment-client.el`: `neoment-room-display-name`, and a new `alias` slot on `neoment-invited-room`.
- `neoment-storage.el`: converting rooms and invited rooms to and from JSON.
- `neoment-rooms.el`: messages from `neoment-rooms-refresh-room-state`.
- Tests: `test/neoment-events-test.el` (its alias tests currently assert `name` = alias and must change), `test/neoment-sync-test.el` (invite named by alias), and storage round-trip tests.
- Room sorting, buffer names, notifications and pickers already go through `neoment-room-display-name`. Their output changes only for rooms whose alias changed or was removed.
- No API, dependency or keybinding changes.
