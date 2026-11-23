# room-membership Specification

## Purpose

Lets the user change which rooms they belong to: join a room by id or alias, start or reuse a direct message, accept or reject invites, and leave rooms. Leaving and removal are handled consistently.

## Requirements

### Requirement: Join command requires login
`neoment-join` SHALL show `Not logged in` and do nothing when there is no active session.

#### Scenario: Join while logged out
- **WHEN** the user runs `neoment-join` without a session
- **THEN** `Not logged in` is shown

### Requirement: Join a direct message
When the target starts with `@`, `neoment-join` SHALL open an existing DM if one exists: a room with exactly 2 members, the user and the target. It shows `Opening existing DM with <u>`. Otherwise it SHALL show `Creating DM with <u>...` and `POST /createRoom` with `{invite:[user], is_direct:true, preset:"trusted_private_chat"}`, then show `Created DM with <u>` and open the room.

#### Scenario: Existing DM
- **WHEN** the user joins `@bob:s` and a 2-member room with the user and Bob exists
- **THEN** that room opens and no room is created

### Requirement: Join a room or alias
For a `!id` the user is already in, or an alias already known locally, the client SHALL show `Room <x> already joined. Opening...` and open it. Otherwise it SHALL `POST /join/<url-encoded id or alias>?via=<hs>&via=matrix.org[&via=...]`, show `Successfully joined room <x>` or `Failed to join room <x>: <e>`, and open the room on success.

#### Scenario: Join new alias
- **WHEN** the user joins `#emacs:matrix.org`, which is not known locally
- **THEN** a join request is sent with `via` parameters, and on success the room opens

### Requirement: Invite response
Activating an invited room in the room list SHALL ask `You have been invited to join the room: <name>` with Join/Reject/Cancel. Join SHALL join and open the room. Reject SHALL leave the room and show `Left room: <name>`.

#### Scenario: Reject invite
- **WHEN** the user picks Reject
- **THEN** `POST /rooms/<r>/leave` is sent and `Left room: <name>` is shown

### Requirement: Leave room
`neoment-room-leave` SHALL ask `Are you sure you want to leave the room <name>?` (default No). On success it SHALL show `Left room <name>`, kill the room buffer and refresh the room list. A "Not a known room" error SHALL remove the room locally and show `Removed room <name> from list`. `M_FORBIDDEN` SHALL count as success.

#### Scenario: Server already removed user
- **WHEN** the leave request fails with `M_FORBIDDEN`
- **THEN** it is treated as a successful leave

### Requirement: History never removes rooms
The user's own leave events that arrive through history pagination MUST NOT remove the room or open a dialog. They only appear as membership lines in the timeline.

#### Scenario: Old self-leave in history
- **WHEN** paginating history returns the user's own leave from last year
- **THEN** the room stays in the list and a membership line is shown
