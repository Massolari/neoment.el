# matrix-events Specification

## Purpose

Defines how incoming Matrix events become the room and message model: messages, edits, replies, threads, redactions, reactions, receipts, membership text and state. It also defines the derived rules the UI relies on.

## Requirements

### Requirement: Event deduplication and ordering
Within a room, an event whose `event_id` was already seen SHALL be ignored. Each batch SHALL be sorted by `origin_server_ts` before processing. After each event is handled, any pending edits, redactions or reactions waiting for it SHALL be processed.

#### Scenario: Duplicate event
- **WHEN** the same `event_id` arrives in two syncs
- **THEN** it is processed only once

#### Scenario: Reaction before target
- **WHEN** a reaction arrives before its target message, and the target arrives later
- **THEN** the reaction is attached to the target once the target is processed

### Requirement: Room account data and state events
The client SHALL apply:
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
`m.room.canonical_alias` SHALL set `aliases = [alias] + alt_aliases` and name the room after the first alias if it has no name. It SHALL also add a state message: `<sender> set the room aliases to <a, b>`, or `<sender> removed the room aliases` when the alias list is empty.

#### Scenario: Aliases removed
- **WHEN** a canonical alias event has no alias and no alt_aliases
- **THEN** a state message `<sender> removed the room aliases` is added

### Requirement: Read receipts
`m.receipt` SHALL only take receipts from the current user on the main thread (`thread_id` missing or `"main"`), keeping the one with the highest `ts`. A local receipt SHALL always be replaced by one from the server. A receipt without `ts` SHALL move to its event and keep the previous ts. If `fully_read` is unset, it SHALL be set to the receipt's event.

#### Scenario: Thread receipt ignored
- **WHEN** a receipt has `thread_id` `$root`
- **THEN** the room's read receipt does not change

#### Scenario: Server replaces local receipt
- **WHEN** a local receipt with ts 2000 exists and a server receipt with ts 1000 arrives
- **THEN** the server receipt is kept

### Requirement: Message content
`m.room.message` and `m.sticker` events without `content.body` SHALL be ignored. The message content is `body`. `formatted_content` is `formatted_body` when the format is `org.matrix.custom.html` and it is not `"* "`. `m.new_content` overrides both. Mentions come from `m.mentions.user_ids`. A redacted event (`unsigned.redacted_because`) shows `[Redacted]`, or `[Redacted by <name>]` when the redactor is not the author.

#### Scenario: Redacted by moderator
- **WHEN** a message's `redacted_because.sender` differs from the author
- **THEN** its content is `[Redacted by <moderator name>]`

### Requirement: Edits
An `m.replace` relation SHALL change the target's content to `m.new_content`, set `edit_data = {id: target, timestamp}` and change the message's id to the edit event id, keeping the original key. This happens only if the edit is newer than the last one applied. Edits to unknown targets SHALL be pending. Edits embedded in `unsigned["m.relations"]["m.replace"]` SHALL be processed too.

#### Scenario: Older edit ignored
- **WHEN** an edit with ts 100 arrives after an edit with ts 200 was applied
- **THEN** the content stays at the ts-200 version

### Requirement: Replies
An `m.in_reply_to` relation SHALL set `replying_to` to the replied message (id = `in_reply_to.event_id`). The replied event is fetched asynchronously if not loaded, using its `m.replace` replacement when there is one. The replied message's mentions SHALL be added to the reply's mentions. A relation with `is_falling_back: true` MUST NOT be treated as a reply.

#### Scenario: Thread fallback
- **WHEN** a thread message has `m.in_reply_to` with `is_falling_back: true`
- **THEN** it has no `replying_to`

#### Scenario: Async fetch
- **WHEN** the replied event is not loaded
- **THEN** the message renders with a placeholder reply, and the room re-renders once `GET /rooms/<r>/event/<id>` returns

### Requirement: Attachments
Messages with msgtype `m.image`, `m.file`, `m.audio`, `m.video` or `m.location`, and `m.sticker` events (as image), all with `content.url`, SHALL carry an attachment. The download URL is `<hs>/_matrix/client/v1/media/download/<server>/<id>`. Video and location thumbnails come from `info.thumbnail_url`/`thumbnail_info`. A location `geo:lat,lon` maps to `https://maps.google.com/?q=lat,lon`.

#### Scenario: Image attachment
- **WHEN** an `m.image` has url `mxc://s/abc`
- **THEN** the attachment url is `<hs>/_matrix/client/v1/media/download/s/abc` and `mxc_url` is `mxc://s/abc`

### Requirement: Threads
`rel_type == "m.thread"` SHALL set `thread_root_id`. A root's `thread_replies_count` comes from `unsigned["m.relations"]["m.thread"].count`. Each new thread reply SHALL add one to the loaded root's count.

#### Scenario: New thread reply
- **WHEN** a reply in thread `$r` arrives and `$r` has count 2
- **THEN** the count becomes 3

### Requirement: Membership events and text
`m.room.member` `join` SHALL add a member, and `leave`/`ban` SHALL remove one. The display name is updated when present. A state message `Membership: <target> <action>` SHALL be generated using these actions:
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

### Requirement: Redactions
`m.room.redaction` of an unknown target SHALL be pending. A target that is already redacted is ignored. Redacting an edit event SHALL remove the edited message entry. Redacting a normal message SHALL set content `[Redacted]` (or `[Redacted: <reason>]`) and `was_redacted`. Redacting a reaction SHALL remove it, and delete the key when its list becomes empty.

#### Scenario: Redact last reaction
- **WHEN** the only 👍 reaction on a message is redacted
- **THEN** the message has no `👍` key

### Requirement: Reactions
`m.reaction` with `m.annotation` SHALL add `{event_id, sender}` under `reactions[key]` of the target message, or become pending if the target is unknown.

#### Scenario: Two users react
- **WHEN** two users react 👍 to a message
- **THEN** `reactions["👍"]` has two entries

### Requirement: Room tracking
A room SHALL be tracked while its buffer is open. An untracked room keeps only its last non-state message and drops events. Opening a buffer SHALL start tracking, clear messages and reload history. Closing it SHALL stop tracking, keep only the last message, and clear `events`, `pending_events` and `prev_batch`.

#### Scenario: Untracked room receives messages
- **WHEN** an untracked room receives 3 messages in one sync
- **THEN** only the newest non-state message is kept

### Requirement: Derived room rules
The client SHALL derive:
- **display name**: `name` if it is not the id; otherwise up to 2 other members' names joined by `", "`, plus `" and <n> others"`; otherwise `Empty room`
- **space name**: `<Space>/<Room>`
- **is space**: `space_rooms` is non-empty
- **room's space**: the first space that lists it (cached)
- **membership**: the user is in `members`

#### Scenario: Unnamed room with three other members
- **WHEN** a room has no name and members Alice, Bob, Carol besides the user
- **THEN** its display name is `Alice, Bob and 1 others`

### Requirement: Unread rule
A room SHALL be unread when `unread` is set manually, or when `last_activity.event_id` exists and differs from both `read_receipt.event_id` and `fully_read`.

#### Scenario: Unread with zero counts
- **WHEN** notification counts are 0 but the last activity id differs from the receipt and fully_read
- **THEN** the room is unread

### Requirement: Ordering and last activity
Messages SHALL be sorted by ascending `timestamp`, and on a tie by larger `age` first. Last activity SHALL update when the timestamp is greater, or equal with a smaller `age`.

#### Scenario: Timestamp tie
- **WHEN** two messages share a timestamp with ages 500 and 100
- **THEN** the age-500 message is ordered first

### Requirement: Display names and effective ids
A user's display name SHALL be the most recent by timestamp. Otherwise it is fetched asynchronously from `GET /profile/<user>/displayname` and cached, falling back to the user id. A message's effective id for replying and reacting SHALL be `edit_data.id` when edited, otherwise `id`.

#### Scenario: React to edited message
- **WHEN** the user reacts to a message that was edited
- **THEN** the reaction targets the original event id
