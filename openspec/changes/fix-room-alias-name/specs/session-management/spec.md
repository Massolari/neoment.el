# Spec Delta

## MODIFIED Requirements

### Requirement: Compact room cache
`cache.json` SHALL hold `sync_token`, `invited_rooms` (each with its name and alias), and a reduced form of each room: id, name, explicit_name, aliases, tombstone, avatar_url, topic, last_activity, is_direct, is_favorite, is_lowpriority, space_rooms, members, unread counts, joined_member_count, unread, read_receipt, and only the last message. `events`, `pending_events`, `typing` and `prev_batch` MUST be empty, and `is_tracked` false.

#### Scenario: Room with many messages saved
- **WHEN** a tracked room with 50 loaded messages is saved
- **THEN** the cached room contains exactly one message and `is_tracked` is false

## ADDED Requirements

### Requirement: Cached room name
A cached room's `explicit_name` SHALL be its explicit name, or null when it has none. A name derived from an alias MUST NOT be stored as `explicit_name`. `name` SHALL still be written, holding the explicit name or the room id, so older versions can read the cache. A cached room without the `explicit_name` key (written by an earlier version) SHALL take its explicit name from `name`, unless `name` equals the room id or one of the room's cached aliases.

#### Scenario: Unnamed room survives a restart
- **WHEN** a room without an explicit name and with alias `#old:s` is saved and loaded again, and then a canonical alias event sets the alias to `#new:s`
- **THEN** the cached room's `explicit_name` is null, its `name` is the room id, and the loaded room's display name becomes `#new:s`

#### Scenario: Legacy cache with an alias-derived name
- **WHEN** `cache.json` holds a room with `name` `#old:s`, aliases `["#old:s"]` and no `explicit_name`
- **THEN** the loaded room has no explicit name, and a later alias change to `#new:s` makes its display name `#new:s`

#### Scenario: Legacy cache with an explicit name
- **WHEN** `cache.json` holds a room with `name` `Dev`, aliases `["#dev:s"]` and no `explicit_name`
- **THEN** the loaded room's explicit name is `Dev`
