# Spec Delta

## MODIFIED Requirements

### Requirement: Room buffer identity
A room buffer SHALL be named `*neoment-room: <Space/Name>*`. The name SHALL NOT contain the room ID, except when the room's display name is not known yet (for example, a room opened right after joining, before the next sync); then `neoment-room-display-name` falls back to the room ID. When another buffer already has that name, Emacs' standard `<N>` suffix tells them apart. If the room's buffer already exists, opening the room again shows and re-renders it. The initial content SHALL be 28 spaces + ` │ ` + `Loading...`.

#### Scenario: Reopen existing room
- **WHEN** the user opens a room whose buffer already exists
- **THEN** that buffer is displayed and no second buffer is created

#### Scenario: Room buffer name
- **WHEN** the user opens room `!r:s`, whose display name is `dev`, which is in no space
- **THEN** the buffer is named `*neoment-room: dev*`

#### Scenario: Two rooms with the same display name
- **WHEN** the user opens two different rooms that are both displayed as `dev`
- **THEN** the buffers are named `*neoment-room: dev*` and `*neoment-room: dev*<2>`, and each one shows its own room
