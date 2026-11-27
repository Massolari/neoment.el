# Spec Delta

## MODIFIED Requirements

### Requirement: Room account data and state events
The client SHALL apply:
- `m.fully_read` → `fully_read`
- `m.marked_unread` → `unread`
- `m.tag` → favourite / lowpriority
- `m.room.name` → name (the explicit name; a missing or empty `name` clears it, leaving the room unnamed)
- `m.room.topic` → topic
- `m.room.avatar` → `avatar_url`
- `m.room.tombstone` → `{body or "This room has been upgraded", replacement_room}`
- `m.space.child` → add `state_key` to `space_rooms`
- `m.typing` → `typing = user_ids`

#### Scenario: Tombstone without body
- **WHEN** an `m.room.tombstone` has no `body`
- **THEN** the tombstone body is `This room has been upgraded`

#### Scenario: Empty name falls back to the alias
- **WHEN** a room with name `dev` and aliases `#dev:s` receives an `m.room.name` with an empty `name`
- **THEN** the room has no explicit name and its display name is `#dev:s`

### Requirement: Canonical alias handling
`m.room.canonical_alias` SHALL set `aliases = [alias] + alt_aliases`, ignoring empty entries. It MUST NOT change the room's explicit name. It SHALL also add a state message: `<sender> set the room aliases to <a, b>`, or `<sender> removed the room aliases` when the alias list is empty.

#### Scenario: Aliases removed
- **WHEN** a canonical alias event has no alias and no alt_aliases
- **THEN** a state message `<sender> removed the room aliases` is added

#### Scenario: Alias changed on an unnamed room
- **WHEN** a room without an explicit name has alias `#old:s` and a canonical alias event sets the alias to `#new:s`
- **THEN** its display name is `#new:s`

#### Scenario: Alias removed from an unnamed room
- **WHEN** a room without an explicit name has alias `#old:s` and a canonical alias event has no alias and no alt_aliases
- **THEN** its display name no longer is `#old:s` and comes from heroes or members instead

#### Scenario: Alias does not replace an explicit name
- **WHEN** a room named `dev` receives a canonical alias event with alias `#dev:s`
- **THEN** its display name stays `dev`

### Requirement: Derived room rules
The client SHALL derive:
- **display name**: the explicit name if the room has one; otherwise the first alias (the canonical alias, else the first `alt_aliases` entry); otherwise the name from `summary` heroes; otherwise up to 2 other members' names joined by `", "`, plus `" and <n> others"`; otherwise `Empty room`
- **space name**: `<Space>/<Room>`
- **is space**: `space_rooms` is non-empty
- **room's space**: the first space that lists it (cached)
- **membership**: the user is in `members`

#### Scenario: Unnamed room with three other members
- **WHEN** a room has no name, no alias and no heroes, and members Alice, Bob, Carol besides the user
- **THEN** its display name is `Alice, Bob and 1 others`

#### Scenario: Unnamed room with an alias
- **WHEN** a room has no explicit name, aliases `#dev:s` and `#alt:s`, and heroes Alice and Bob
- **THEN** its display name is `#dev:s`

#### Scenario: Explicit name wins over alias
- **WHEN** a room has explicit name `Dev chat` and alias `#dev:s`
- **THEN** its display name is `Dev chat`
