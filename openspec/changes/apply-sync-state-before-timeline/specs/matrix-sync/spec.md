# Spec Delta

## MODIFIED Requirements

### Requirement: Joined rooms
For each room in `rooms.join`, the client SHALL process, in this order: `account_data.events`, `state.events`, `timeline.events`, `summary`, `ephemeral.events`, `unread_notifications`. It SHALL set `joined_member_count` from `summary["m.joined_member_count"]`. When the unread counts change, it SHALL update them and fire the notification trigger with the old and new counts.

#### Scenario: Unread counts change
- **WHEN** `notification_count` goes from 0 to 2
- **THEN** the room's count becomes 2 and the desktop-notification trigger gets old=0, new=2

## ADDED Requirements

### Requirement: Timeline state wins over the state block
A joined room's `state.events` describes the room before its `timeline.events`. When both carry the same state (same type and state key), the value from `timeline.events` SHALL be the room's current state. State only present in `state.events` SHALL still apply.

#### Scenario: Room renamed inside a limited timeline
- **WHEN** a limited sync for a joined room has `m.room.name` `Old` (ts 100) in `state.events` and `m.room.name` `New` (ts 2000) in `timeline.events`
- **THEN** the room's name is `New`

#### Scenario: Member who joined in the timeline stays a member
- **WHEN** a limited sync has `@bob:s` with membership `leave` in `state.events` and `@bob:s` with membership `join` in `timeline.events`
- **THEN** `@bob:s` is a member of the room

#### Scenario: State block alone still applies
- **WHEN** a sync has `m.room.topic` `Hello` in `state.events` and no topic event in `timeline.events`
- **THEN** the room's topic is `Hello`
