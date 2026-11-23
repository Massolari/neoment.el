# matrix-sync Specification

## Purpose

Keeps the local model in step with the homeserver. It runs a continuous `/sync` long-poll loop, reports sync status, retries on errors, and applies invited, joined and left rooms, global account data and presence in a fixed order.

## Requirements

### Requirement: Sync request
Each sync SHALL `GET /_matrix/client/v3/sync` with:
- the inline URL-encoded filter `{"room":{"state":{"lazy_load_members":true},"timeline":{"limit":1,"lazy_load_members":true}}}`
- `full_state=true` only on the first sync
- `set_presence=<desired presence or "online">`
- `since=<sync_token>` when one exists
- `timeout=30000`

The request SHALL have a client-side timeout of 45 s. Reaching it counts as a sync error.

#### Scenario: First sync
- **WHEN** no sync has completed yet
- **THEN** the request includes `full_state=true` and no `since`

#### Scenario: Desired presence
- **WHEN** the user chose `unavailable` as their status
- **THEN** the next sync request uses `set_presence=unavailable`

#### Scenario: Silent connection drop
- **WHEN** the connection dies without an error after the laptop wakes from sleep
- **THEN** after 45 s the request fails as a sync error and the loop retries

### Requirement: Single continuous loop
After a sync finishes (success or handled error), the next one SHALL start right away until sync is stopped. Two syncs MUST never run at the same time. `neoment-sync-start` SHALL show `Synchronization started` and `neoment-sync-stop` SHALL show `Synchronization stopped`. An error while processing a response SHALL be reported as a sync error, and the loop SHALL continue.

#### Scenario: Start while running
- **WHEN** `neoment-sync-start` is called while a sync request is in flight
- **THEN** no second concurrent sync request is issued

#### Scenario: Processing error
- **WHEN** a malformed event raises an error while a sync response is processed
- **THEN** the error is reported as a sync error and the next sync still starts

### Requirement: Sync status
The client SHALL expose a sync status with `kind` (`syncing`/`stopped`), `last_sync` (epoch seconds) and `current_count`, for the room list to show.

#### Scenario: After a successful sync
- **WHEN** a sync completes
- **THEN** `last_sync` is updated to the current time

### Requirement: Sync error retries
For up to 3 consecutive errors, the client SHALL show `Error syncing: <error>\nRetrying...` and retry after 1 s. After that it SHALL show only `Error syncing: <error>`. An expired session SHALL stop the loop.

#### Scenario: Fourth consecutive error
- **WHEN** the fourth consecutive sync error occurs
- **THEN** the message is `Error syncing: <error>` without `Retrying...`

### Requirement: Processing order
A sync response SHALL be processed in this order: clear notification candidates, `rooms.invite`, `rooms.join`, `rooms.leave`, global `account_data`, `presence`, clear notification candidates again. Afterwards the room list (if open) SHALL refresh, and so SHALL every open room buffer whose room changed.

#### Scenario: Open room changed
- **WHEN** a sync brings a new message for a room whose buffer is open
- **THEN** that room buffer is re-rendered and buffers of unchanged rooms are not

### Requirement: Invited rooms
For each room in `rooms.invite`, the client SHALL read stripped `invite_state.events`:
- `m.room.name` → name
- `m.room.canonical_alias` → name = alias, or the first `alt_aliases` entry
- `m.room.topic` → topic
- `m.room.avatar` → avatar_url
- `m.room.member` with `join` → member, using displayname or id

#### Scenario: Invite named by alias
- **WHEN** an invite has only a canonical alias `#dev:example.org`
- **THEN** the invited room's name is `#dev:example.org`

### Requirement: Joined rooms
For each room in `rooms.join`, the client SHALL process, in this order: `account_data.events`, `timeline.events`, `state.events`, `summary`, `ephemeral.events`, `unread_notifications`. It SHALL set `joined_member_count` from `summary["m.joined_member_count"]`. When the unread counts change, it SHALL update them and fire the notification trigger with the old and new counts.

#### Scenario: Unread counts change
- **WHEN** `notification_count` goes from 0 to 2
- **THEN** the room's count becomes 2 and the desktop-notification trigger gets old=0, new=2

### Requirement: Room name from heroes
When a room has no name (name equals id), the client SHALL name it from `summary` heroes:
- if `#heroes >= joined + invited - 1`, the hero names joined by `", "`
- otherwise, if `joined + invited > 1`, `"<h1>, <h2> and <n> others"`
- otherwise `"Empty room"`, or `"Empty room (was <h1> and <n> others)"`, or `"Empty room (was <h1>)"`

#### Scenario: Two heroes, five members
- **WHEN** heroes are Alice and Bob, with 5 joined and 0 invited
- **THEN** the name is `Alice, Bob and 3 others`

### Requirement: Left rooms
`rooms.leave` SHALL apply only to known (joined or invited) rooms and remove them from the list. Unknown rooms MUST NOT be created. Outside the initial sync, if another user sent the user's last `leave`/`ban` membership event, the client SHALL show the acknowledgement dialog `Room: <name>\n\n<membership text>\n\nPress OK to acknowledge.`

#### Scenario: Kicked by another user
- **WHEN** a non-initial sync reports the user left because `@mod` sent a `leave`
- **THEN** the room is removed and the dialog shows `Membership: <user> was removed from the room by <mod>`

#### Scenario: Self-leave
- **WHEN** the user's own leave arrives in `rooms.leave`
- **THEN** the room is removed and no dialog is shown

#### Scenario: Unknown room
- **WHEN** `rooms.leave` contains a room the client never knew
- **THEN** no room is created

### Requirement: Global account data
`m.direct` SHALL set `is_direct = true` on every listed room that already exists. `m.push_rules` SHALL replace the stored push ruleset.

#### Scenario: m.direct
- **WHEN** `m.direct` lists room `!a:s` for `@bob:s`
- **THEN** room `!a:s` is direct

### Requirement: Presence
`m.presence` events SHALL record `presence`, `last_active_ago`, `status_msg` and `currently_active` for each user.

#### Scenario: Presence update
- **WHEN** a presence event says `@bob:s` is `unavailable`
- **THEN** the stored presence for `@bob:s` is `unavailable`
