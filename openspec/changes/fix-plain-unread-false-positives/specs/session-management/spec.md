# Spec Delta

## MODIFIED Requirements

### Requirement: Compact room cache
`cache.json` SHALL hold `sync_token`, `invited_rooms`, and a reduced form of each room: id, name, aliases, tombstone, avatar_url, topic, last_activity, unread_activity, is_direct, is_favorite, is_lowpriority, space_rooms, members, unread counts, joined_member_count, unread, read_receipt, fully_read, and only the last message. `events`, `pending_events`, `typing` and `prev_batch` MUST be empty, and `is_tracked` false.

#### Scenario: Room with many messages saved
- **WHEN** a tracked room with 50 loaded messages is saved
- **THEN** the cached room contains exactly one message and `is_tracked` is false

#### Scenario: Unread activity round trip
- **WHEN** a room whose unread activity differs from its last activity is saved and restored
- **THEN** the restored room has the same unread activity and the same unread state

## ADDED Requirements

### Requirement: Cache without unread activity
When a cached room has no `unread_activity`, as in a cache written by an older version, the restored room SHALL use its `last_activity` as unread activity.

#### Scenario: Cache from an older version
- **WHEN** a cached room has `last_activity` but no `unread_activity`
- **THEN** the restored room's unread activity equals its last activity
