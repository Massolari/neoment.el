# Spec Delta

## MODIFIED Requirements

### Requirement: Invited rooms
For each room in `rooms.invite`, the client SHALL read stripped `invite_state.events`:
- `m.room.name` → name, when not empty
- `m.room.canonical_alias` → alias = the alias, or the first `alt_aliases` entry
- `m.room.topic` → topic
- `m.room.avatar` → avatar_url
- `m.room.member` with `join` → member, using displayname or id

#### Scenario: Invite named by alias
- **WHEN** an invite has only a canonical alias `#dev:example.org`
- **THEN** the invited room's display name is `#dev:example.org`

### Requirement: Room name from heroes
When a room has no explicit name and no alias, the client SHALL name it from `summary` heroes:
- if `#heroes >= joined + invited - 1`, the hero names joined by `", "`
- otherwise, if `joined + invited > 1`, `"<h1>, <h2> and <n> others"`
- otherwise `"Empty room"`, or `"Empty room (was <h1> and <n> others)"`, or `"Empty room (was <h1>)"`

#### Scenario: Two heroes, five members
- **WHEN** an unnamed room without aliases has heroes Alice and Bob, with 5 joined and 0 invited
- **THEN** the name is `Alice, Bob and 3 others`

#### Scenario: Alias wins over heroes
- **WHEN** an unnamed room has alias `#dev:s` and heroes Alice and Bob
- **THEN** the name is `#dev:s`

## ADDED Requirements

### Requirement: Invited room display name
An invited room's display name SHALL be its name, otherwise its alias, otherwise its other members' names, otherwise `Empty room`. The result MUST NOT depend on the order in which the stripped state events arrive.

#### Scenario: Invite name wins over a later alias
- **WHEN** an invite's stripped state has `m.room.name` `Dev` followed by `m.room.canonical_alias` `#dev:s`
- **THEN** the invited room's display name is `Dev`

#### Scenario: Invite alias then name
- **WHEN** an invite's stripped state has `m.room.canonical_alias` `#dev:s` followed by `m.room.name` `Dev`
- **THEN** the invited room's display name is `Dev`
