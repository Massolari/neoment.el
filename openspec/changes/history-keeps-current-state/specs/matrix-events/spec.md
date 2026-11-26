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

#### Scenario: Fetched display name beats history
- **WHEN** the display name `Bob2` of `@bob:s` was learned from `joined_members` or `GET /profile`, and a history page then delivers a `join` for `@bob:s` at ts 100 with displayname `Bob1`
- **THEN** the display name of `@bob:s` is still `Bob2`

#### Scenario: Sync still applies state
- **WHEN** a history page delivers `m.room.name` `Old`, and a sync then delivers `m.room.name` `New`
- **THEN** the room name is `New`

## MODIFIED Requirements

### Requirement: Room account data and state events
The client SHALL apply the following. The state events (`m.room.name`, `m.room.topic`, `m.room.avatar`, `m.room.tombstone`, `m.space.child`) change state only when they don't come from paginated history.
- `m.fully_read` → `fully_read`
- `m.marked_unread` → `unread`
- `m.tag` → favourite / lowpriority
- `m.room.name` → name
- `m.room.topic` → topic
- `m.room.avatar` → `avatar_url`
- `m.room.tombstone` → `{body or "This room has been upgraded", replacement_room}`
- `m.space.child` → add `state_key` to `space_rooms`
- `m.typing` → `typing = user_ids`

#### Scenario: Tombstone without body
- **WHEN** an `m.room.tombstone` has no `body`
- **THEN** the tombstone body is `This room has been upgraded`

### Requirement: Canonical alias handling
`m.room.canonical_alias` from outside paginated history SHALL set `aliases = [alias] + alt_aliases` and name the room after the first alias if it has no name. Every canonical alias event, history included, SHALL add a state message: `<sender> set the room aliases to <a, b>`, or `<sender> removed the room aliases` when the alias list is empty.

#### Scenario: Aliases removed
- **WHEN** a canonical alias event has no alias and no alt_aliases
- **THEN** a state message `<sender> removed the room aliases` is added

### Requirement: Membership events and text
`m.room.member` `join` from outside paginated history SHALL add a member, and `leave`/`ban` SHALL remove one. The display name is updated when present, following the display name rule. Every membership event, history included, SHALL generate a state message `Membership: <target> <action>` using these actions:
- join, changed display name, changed avatar
- left, invite revoked / rejected, removed by, unbanned by, knock denied / retracted
- invited / re-invited / knock accepted
- banned / kicked and banned
- knocking / re-knocking

Other memberships produce no message.

#### Scenario: Kick
- **WHEN** a `leave` has prev `join` and the sender differs from the target
- **THEN** the text is `Membership: <target> was removed from the room by <sender>`

#### Scenario: Display name change
- **WHEN** a `join` has prev `join` with displayname A and new displayname B
- **THEN** the text is `Membership: B changed display name from A to B`

### Requirement: Display names and effective ids
A user's display name SHALL be the most recent by timestamp. A name learned from `joined_members` or from `GET /profile` is current, so it SHALL be stored with the time it was learned. Otherwise the name is fetched asynchronously from `GET /profile/<user>/displayname` and cached, falling back to the user id. A failed fetch SHALL NOT stop a later member event from supplying the name. A message's effective id for replying and reacting SHALL be `edit_data.id` when edited, otherwise `id`.

#### Scenario: React to edited message
- **WHEN** the user reacts to a message that was edited
- **THEN** the reaction targets the original event id
