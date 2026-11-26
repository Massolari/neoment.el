# Spec Delta

## ADDED Requirements

### Requirement: Paginated history keeps current state
State events from a paginated history page (both `chunk` and `state` of `GET /rooms/<r>/messages`) SHALL NOT change the room's current state: `name`, `topic`, `avatar_url`, `tombstone`, `aliases`, `members` or `space_rooms`. They SHALL still add their timeline state messages (membership text, canonical alias text). A display name from history SHALL never replace a newer one. Events from `/sync` and `GET /rooms/<r>/state` are applied as before.

#### Scenario: Older name in history
- **WHEN** a sync sets the room name to `New` and a history page then delivers an older `m.room.name` with name `Old`
- **THEN** the room name is still `New`

#### Scenario: Topic and avatar in history
- **WHEN** the room has topic `T2` and avatar `mxc://s/a2`, and a history page delivers older `m.room.topic` `T1` and `m.room.avatar` `mxc://s/a1`
- **THEN** the topic is still `T2` and the avatar is still `mxc://s/a2`

#### Scenario: Tombstone in history
- **WHEN** a room has no tombstone and a history page delivers an `m.room.tombstone`
- **THEN** the room still has no tombstone

#### Scenario: Space child in history
- **WHEN** a history page delivers an `m.space.child` with content for `!child:s`
- **THEN** `!child:s` is not added to `space_rooms`

#### Scenario: Older aliases in history
- **WHEN** the room has aliases `#new:s` and a history page delivers an older canonical alias event with alias `#old:s`
- **THEN** the aliases are still `#new:s`, and the state message `<sender> set the room aliases to #old:s` is in the timeline

#### Scenario: Alias in history does not name an unnamed room
- **WHEN** a room has no name and no aliases, and a history page delivers a canonical alias event with alias `#old:s`
- **THEN** the room name is still the room id

#### Scenario: Old leave in history
- **WHEN** `@bob:s` is a member and a history page delivers an older `leave` for `@bob:s`
- **THEN** `@bob:s` is still a member, and the `Membership: … left the room` message is in the timeline

#### Scenario: Old join in history
- **WHEN** `@carol:s` is not a member and a history page delivers an older `join` for `@carol:s`
- **THEN** `@carol:s` is still not a member, and the `Membership: … joined the room` message is in the timeline

#### Scenario: Older display name in history
- **WHEN** `@bob:s` has display name `Bob2` from a sync at ts 2000, and a history page delivers a `join` for `@bob:s` at ts 100 with displayname `Bob1`
- **THEN** the display name of `@bob:s` is still `Bob2`

#### Scenario: Sync still applies state
- **WHEN** a history page delivers `m.room.name` `Old`, and a sync then delivers `m.room.name` `New`
- **THEN** the room name is `New`
