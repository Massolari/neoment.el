# Spec Delta

## MODIFIED Requirements

### Requirement: Ordering
Spaces SHALL be sorted by name (case-insensitive, ties by id). The other sections SHALL order rooms in three groups: first rooms with unread highlights or notifications, then other unread rooms, then read rooms. Within each group, the most recent activity SHALL come first. Highlights and notifications SHALL share the first group and SHALL NOT be ranked against each other.

#### Scenario: Unread before recent
- **WHEN** room A is read with activity 1 min ago and room B is unread with activity 1 h ago
- **THEN** B is listed before A

#### Scenario: Notifications before unread
- **WHEN** room A is unread without counts and has activity 1 min ago, and room B has 1 unread notification and activity 1 h ago
- **THEN** B is listed before A

#### Scenario: Highlights before unread
- **WHEN** room A is unread without counts and has activity 1 min ago, and room B has 1 unread highlight and activity 1 h ago
- **THEN** B is listed before A

#### Scenario: Counts rank first even when read
- **WHEN** room A is unread without counts and has activity 1 min ago, and room B has 1 unread notification, activity 1 h ago, and its read marker on its last event
- **THEN** B is listed before A

#### Scenario: Highlights and notifications ordered by activity
- **WHEN** room A has 1 unread highlight and activity 1 h ago, and room B has 1 unread notification and activity 1 min ago
- **THEN** B is listed before A

#### Scenario: Full ordering within a section
- **WHEN** a section holds a read room with activity 1 min ago, an unread room with activity 5 min ago, and a room with notifications with activity 1 h ago
- **THEN** they are listed as: the room with notifications, the unread room, the read room

### Requirement: Toggle read state
`r` SHALL mark an unread room (highlights, notifications, or the unread rule) as read with a private `m.read.private` receipt on the last activity event, and show `Room '<n>' marked as read`. When the receipt succeeds, the room's highlight and notification counts SHALL be set to 0 locally, so the room leaves the notifications group before the next sync. Otherwise it SHALL send `m.marked_unread {unread:true}` and show `Room '<n>' marked as unread`.

#### Scenario: Mark read room as unread
- **WHEN** the user presses `r` on a read room
- **THEN** an `m.marked_unread` event with `unread: true` is sent

#### Scenario: Mark as read clears counts
- **WHEN** the user presses `r` on a room with 1 unread notification and the receipt succeeds
- **THEN** the room has no highlights or notifications and is no longer listed in the notifications group
