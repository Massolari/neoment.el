# Spec Delta

## MODIFIED Requirements

### Requirement: Room info buffer
The buffer SHALL be named `*neoment-room-info: <Space/Name>*`, without the room ID. When opened from a room it shows in a window to the right, 50 columns wide.

#### Scenario: Open from room
- **WHEN** the user presses `i` in a room buffer
- **THEN** the info buffer appears in a 50-column window to the right

#### Scenario: Info buffer name
- **WHEN** the user opens the information of room `!r:s`, displayed as `dev`
- **THEN** the buffer is named `*neoment-room-info: dev*`
