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
An `m.replace` relation SHALL change the target's content to `m.new_content`, set `edit_data = {id: target, timestamp}` and change the message's id to the edit event id, keeping the original key. This happens only if the edit is newer than the last one applied. Edits to unknown targets SHALL be pending. Edits embedded in `unsigned["m.relations"]["m.replace"]` SHALL be processed too. A room SHALL always store a message under its effective id (the original event id), never under the id of an edit. An edit whose target has `was_redacted` set MUST be ignored, whatever order the events arrive in.

#### Scenario: Older edit ignored
- **WHEN** an edit with ts 100 arrives after an edit with ts 200 was applied
- **THEN** the content stays at the ts-200 version

#### Scenario: Edited message found by its original id
- **WHEN** message `$o` is edited by `$oe`
- **THEN** the message is stored under the key `$o`, not `$oe`, and a reaction to `$o` is applied to it

#### Scenario: Edit after redaction ignored
- **WHEN** message `$s` is redacted and then an edit of `$s` with a later timestamp arrives
- **THEN** the content of `$s` stays `[Redacted]`, `was_redacted` stays set, its id stays `$s`, and the room is not marked as changed

#### Scenario: Pending redaction then history with an edit
- **WHEN** a redaction of unknown `$s` is pending, and a history page then delivers `$s` and a later edit of `$s`
- **THEN** after the page is handled the content of `$s` is `[Redacted]` and `was_redacted` is set

#### Scenario: Edit of an event redacted on arrival
- **WHEN** event `$s` arrives with `unsigned.redacted_because` and then an edit of `$s` arrives
- **THEN** `$s` has `was_redacted` set, it keeps its redaction text and its id stays `$s`

### Requirement: Edit validation
An `m.replace` edit MUST be ignored when its `sender` differs from the target message's sender, or when the target is a state message. An ignored edit leaves the target's content, id and `edit_data` unchanged. Pending edits and edits embedded in `unsigned["m.relations"]["m.replace"]` SHALL be checked the same way once the target is known, and a rejected pending edit SHALL stop waiting for its target.

#### Scenario: Edit from another sender ignored
- **WHEN** `@alice:s` sent a message with body `hello` and `@mallory:s` sends an `m.replace` of it with new body `hacked`
- **THEN** the message content stays `hello`, and its id and `edit_data` are unchanged

#### Scenario: Pending edit from another sender ignored
- **WHEN** an `m.replace` from `@mallory:s` arrives before its target, and the target then arrives from `@alice:s`
- **THEN** the target shows its original content and the edit no longer waits for it

#### Scenario: Embedded edit from another sender ignored
- **WHEN** a message from `@alice:s` arrives with an `unsigned["m.relations"]["m.replace"]` event from `@mallory:s`
- **THEN** the message shows its original content

#### Scenario: Edit of a state message ignored
- **WHEN** an `m.replace` from the same sender targets a membership or other state message
- **THEN** the state message is unchanged

#### Scenario: Edit from the same sender applied
- **WHEN** `@alice:s` edits their own message, before or after it arrives
- **THEN** the message shows the new content, as before this change

### Requirement: Replies
An `m.in_reply_to` relation SHALL set `replying_to` to the replied message (id = `in_reply_to.event_id`). The replied event is fetched asynchronously if not loaded, using its `m.replace` replacement when there is one and its sender matches the replied event's sender. A replacement from another sender MUST be ignored and the original event shown. The replied message's mentions SHALL be added to the reply's mentions. A relation with `is_falling_back: true` MUST NOT be treated as a reply.

#### Scenario: Thread fallback
- **WHEN** a thread message has `m.in_reply_to` with `is_falling_back: true`
- **THEN** it has no `replying_to`

#### Scenario: Async fetch
- **WHEN** the replied event is not loaded
- **THEN** the message renders with a placeholder reply, and the room re-renders once `GET /rooms/<r>/event/<id>` returns

#### Scenario: Fetched replacement from another sender
- **WHEN** the fetched replied event is from `@bob:s` with body `question`, and its bundled replacement is from `@mallory:s` with new body `hacked`
- **THEN** the reply quote shows sender `@bob:s` and content `question`

### Requirement: Attachments
Messages with msgtype `m.image`, `m.file`, `m.audio`, `m.video` or `m.location`, and `m.sticker` events (as image), all with `content.url`, SHALL carry an attachment. The download URL is `<hs>/_matrix/client/v1/media/download/<server>/<id>`. Video and location thumbnails come from `info.thumbnail_url`/`thumbnail_info`. A location `geo:lat,lon` maps to `https://maps.google.com/?q=lat,lon`.

#### Scenario: Image attachment
- **WHEN** an `m.image` has url `mxc://s/abc`
- **THEN** the attachment url is `<hs>/_matrix/client/v1/media/download/s/abc` and `mxc_url` is `mxc://s/abc`

### Requirement: Threads
`rel_type == "m.thread"` SHALL set `thread_root_id`. A root's `thread_replies_count` comes from `unsigned["m.relations"]["m.thread"].count`, which already includes the replies that existed when the server sent the root. A thread reply SHALL add one to the loaded root's count unless the root was stored in the same batch (sync response or history page) carrying a server count; in that case the count SHALL stay unchanged. A root without a server count SHALL count its loaded replies locally.

#### Scenario: New thread reply
- **WHEN** root `$r` with count 2 was loaded in an earlier batch and a new reply in thread `$r` arrives live
- **THEN** the count becomes 3

#### Scenario: Root and replies in the same live batch
- **WHEN** one sync batch contains root `$r` with count 2 and its two thread replies
- **THEN** the count stays 2

#### Scenario: Root and replies in a history page
- **WHEN** a paginated history page contains root `$r` with count 2 and its two thread replies
- **THEN** the count stays 2

#### Scenario: Replies loaded before their root
- **WHEN** a history page contains thread replies to `$r`, and a later, older page contains root `$r` with count 2
- **THEN** the count is 2

#### Scenario: Server without thread counts
- **WHEN** one batch contains root `$r` without `unsigned["m.relations"]["m.thread"]` and its two thread replies
- **THEN** the count is 2

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
`m.room.redaction` of an unknown target SHALL be pending. A target that is already redacted is ignored. Redacting an edit event SHALL remove the edited message entry only when that edit was applied: the edit's sender matches the message's sender, and the message is neither a state message nor redacted. Otherwise the message MUST be left unchanged. Redacting a normal message SHALL set content `[Redacted]` (or `[Redacted: <reason>]`) and `was_redacted`, and clear any applied edit (`edit_data` and the edit's id). Redacting a reaction SHALL remove it, and delete the key when its list becomes empty.

#### Scenario: Redact last reaction
- **WHEN** the only 👍 reaction on a message is redacted
- **THEN** the message has no `👍` key

#### Scenario: Redact a foreign edit
- **WHEN** `@mallory:s` sends an `m.replace` of a message from `@alice:s` and then redacts that edit
- **THEN** the message from `@alice:s` is still in the room with its original content

#### Scenario: Redact an edit of a state message
- **WHEN** `@alice:s` sends an `m.replace` of her own membership event and then redacts that edit
- **THEN** the membership event is still in the room with its original content

#### Scenario: Redaction after an edit
- **WHEN** message `$s` is edited by `$e` and then `$s` is redacted
- **THEN** `$s` shows `[Redacted]`, its id is `$s` and it has no `edit_data`

#### Scenario: Redacting an ignored edit
- **WHEN** `$s` is redacted, an edit `$e` of `$s` is ignored, and then `$e` is redacted
- **THEN** `$s` is still in the room with its redaction text

### Requirement: Reactions
`m.reaction` with `m.annotation` SHALL add `{event_id, sender}` under `reactions[key]` of the target message, or become pending if the target is unknown.

#### Scenario: Two users react
- **WHEN** two users react 👍 to a message
- **THEN** `reactions["👍"]` has two entries

### Requirement: Room tracking
A room SHALL be tracked while its buffer is open. An untracked room keeps only its last non-state message and drops events. Opening a buffer SHALL start tracking, clear messages and reload history. Closing it SHALL stop tracking, keep only the last message, and clear `events`, `pending_events` and `prev_batch`. The kept message SHALL stay stored under its effective id, so relations that target it still apply after the buffer is closed.

#### Scenario: Untracked room receives messages
- **WHEN** an untracked room receives 3 messages in one sync
- **THEN** only the newest non-state message is kept

#### Scenario: Closing a buffer keeps an edited message under its original id
- **WHEN** the last message `$o` was edited by `$oe` and the room buffer is closed
- **THEN** the only kept message is stored under `$o`, and a later reaction to `$o` is applied to it instead of going pending

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
