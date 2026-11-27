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

### Requirement: Read receipts
`m.receipt` SHALL only take receipts from the current user on the main thread (`thread_id` missing or `"main"`), keeping the one with the highest `ts`. A local receipt SHALL always be replaced by one from the server. A receipt without `ts` SHALL move to its event and keep the previous ts. If `fully_read` is unset, it SHALL be set to the receipt's event.

#### Scenario: Thread receipt ignored
- **WHEN** a receipt has `thread_id` `$root`
- **THEN** the room's read receipt does not change

#### Scenario: Server replaces local receipt
- **WHEN** a local receipt with ts 2000 exists and a server receipt with ts 1000 arrives
- **THEN** the server receipt is kept

### Requirement: Message content
`m.room.message` and `m.sticker` events without `content.body` SHALL be ignored, unless they carry `unsigned.redacted_because` (see Server-redacted messages). The message content is `body`. `formatted_content` is `formatted_body` when the format is `org.matrix.custom.html` and it is not `"* "`. `m.new_content` overrides both. Mentions come from `m.mentions.user_ids`. A redacted event (`unsigned.redacted_because`) shows `[Redacted]`, or `[Redacted by <name>]` when the redactor is not the author.

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
Messages with msgtype `m.image`, `m.file`, `m.audio` or `m.video`, and `m.sticker` events (as image), all with an mxc `content.url`, SHALL carry an attachment. `m.location` messages SHALL carry one only when `content.geo_uri` is a string starting with `geo:lat,lon` (numeric `lat` and `lon`, optionally followed by `,altitude` or `;parameters`), regardless of `content.url`; any other `geo_uri` gives no attachment. The media download URL is `<hs>/_matrix/client/v1/media/download/<server>/<id>`. Video and location thumbnails come from `info.thumbnail_url`/`thumbnail_info`. A location `geo:lat,lon` maps to `https://maps.google.com/?q=lat,lon`.

#### Scenario: Image attachment
- **WHEN** an `m.image` has url `mxc://s/abc`
- **THEN** the attachment url is `<hs>/_matrix/client/v1/media/download/s/abc` and `mxc_url` is `mxc://s/abc`

#### Scenario: Location with geo_uri and no url
- **WHEN** an `m.location` message has `geo_uri` `geo:-23.5,46.6` and no `url`
- **THEN** it has a location attachment whose url is `https://maps.google.com/?q=-23.5,46.6`

#### Scenario: Location with url but no geo_uri
- **WHEN** an `m.location` message has `url` `mxc://s/l` and no `geo_uri`
- **THEN** it has no attachment

#### Scenario: Location geo_uri with altitude and parameters
- **WHEN** an `m.location` message has `geo_uri` `geo:1.5,-2,30;u=10`
- **THEN** it has a location attachment whose url is `https://maps.google.com/?q=1.5,-2`

#### Scenario: Location with an unusable geo_uri
- **WHEN** an `m.location` message has `geo_uri` `5`, `""`, `foo`, `geo:`, `geo:-,-` or `xgeo:1,2`
- **THEN** it has no attachment

#### Scenario: Edit with an unusable geo_uri keeps the location
- **WHEN** a location message with `geo_uri` `geo:1.5,2.5` is edited by its sender with an `m.new_content` of msgtype `m.location` and `geo_uri` `5` or `""`
- **THEN** the edit is applied and the message keeps its attachment with url `https://maps.google.com/?q=1.5,2.5`

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

### Requirement: Redactions
`m.room.redaction` of an unknown target SHALL be pending. A target that is already redacted is ignored. Redacting an edit event SHALL remove the edited message entry only when that edit was applied: the edit's sender matches the message's sender, and the message is neither a state message nor redacted. Otherwise the message MUST be left unchanged. Redacting a normal message SHALL set content `[Redacted]` (or `[Redacted: <reason>]`) and `was_redacted`, and clear any applied edit (`edit_data` and the edit's id). An `m.sticker` target SHALL be redacted exactly like an `m.room.message` target, and lose its attachment. Redacting a reaction SHALL remove it, and delete the key when its list becomes empty.

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

#### Scenario: Redact a sticker
- **WHEN** a tracked room has sticker `$st` with an image `url`, and a redaction of `$st` with reason `oops` arrives
- **THEN** the room is marked as changed, `$st` shows `[Redacted: oops]`, has `was_redacted` set and has no attachment

#### Scenario: Pending redaction of a sticker
- **WHEN** a redaction of unknown `$st` arrives, and then sticker `$st` arrives
- **THEN** `$st` shows `[Redacted]`, has `was_redacted` set and has no attachment

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
A room SHALL be unread when `unread` is set manually, or when it has unread activity and neither the read receipt nor `fully_read` is at or after it. A marker is at or after the unread activity when it points at the same event, or when its event is loaded with a timestamp greater than or equal to the unread activity's. A loaded event's timestamp SHALL be taken from its own event, including for edit events. When the receipt's event is not loaded, the event timestamp recorded with the receipt SHALL be compared, else the receipt's `ts`. A `fully_read` event that is not loaded SHALL NOT count.

#### Scenario: Unread with zero counts
- **WHEN** notification counts are 0 and neither the receipt nor fully_read is at or after the unread activity
- **THEN** the room is unread

#### Scenario: Marker on the same event
- **WHEN** the read receipt or fully_read points at the unread activity event
- **THEN** the room is read

#### Scenario: Receipt on a later event
- **WHEN** another client moved the user's receipt to a loaded state event newer than the unread activity
- **THEN** the room is read

#### Scenario: Receipt event not loaded
- **WHEN** the receipt points at an event that is not loaded and its `ts` is later than the unread activity's timestamp
- **THEN** the room is read

#### Scenario: Receipt on an edit event
- **WHEN** the receipt or fully_read points at a loaded edit event newer than the unread activity, whose edited message is older
- **THEN** the room is read

#### Scenario: Marker moved back, then unloaded
- **WHEN** the user moved the receipt back to a loaded event older than the unread activity, the server echoed it with a later `ts`, and the event is no longer loaded
- **THEN** the room is unread

#### Scenario: Older receipt
- **WHEN** the receipt points at a loaded event older than the unread activity and fully_read is not at or after it
- **THEN** the room is unread

#### Scenario: Fully read event not loaded
- **WHEN** fully_read points at an event that is not loaded and the receipt is not at or after the unread activity
- **THEN** the room is unread

#### Scenario: No unread activity
- **WHEN** the room has no unread activity and `unread` is not set
- **THEN** the room is read

#### Scenario: Manually marked unread
- **WHEN** `unread` is set and the receipt is on the unread activity
- **THEN** the room is unread

### Requirement: Ordering and last activity
Messages SHALL be sorted by ascending `timestamp`, and on a tie by larger `age` first. Last activity SHALL update when the timestamp is greater, or equal with a smaller `age`. Unread activity SHALL follow the same rule but only for messages and stickers that are not sent by the user and not thread replies. In a `limited` sync timeline, other users' thread replies SHALL also count.

#### Scenario: Timestamp tie
- **WHEN** two messages share a timestamp with ages 500 and 100
- **THEN** the age-500 message is ordered first

#### Scenario: Own message
- **WHEN** the room is read and a message sent by the user arrives, from neoment or another device
- **THEN** last activity moves to the message, unread activity does not, and the room stays read

#### Scenario: Thread reply
- **WHEN** the room is read and another user's thread reply arrives
- **THEN** last activity moves to the reply, unread activity does not, and the room stays read

#### Scenario: Thread reply after a gap
- **WHEN** a `limited` sync timeline holds another user's thread reply
- **THEN** both last activity and unread activity move to it, and the room is unread

#### Scenario: Main timeline message from another user
- **WHEN** another user's message that is not a thread reply arrives after the receipt
- **THEN** both last activity and unread activity move to it, and the room is unread

### Requirement: Display names and effective ids
A member event from outside paginated history SHALL set the user's display name unless a newer member event already set it. A name learned from `joined_members` or from `GET /profile` is current: a later live member event replaces it, but a member event from history SHALL NOT. A history member event MAY set the name when none is known, or when the known name came from an older member event. When no name is known, it is fetched asynchronously from `GET /profile/<user>/displayname` and cached, falling back to the user id. A failed fetch SHALL NOT stop a later member event from supplying the name. A message's effective id for replying and reacting SHALL be `edit_data.id` when edited, otherwise `id`.

#### Scenario: React to edited message
- **WHEN** the user reacts to a message that was edited
- **THEN** the reaction targets the original event id

### Requirement: Server-redacted messages
A message event that arrives already redacted (`unsigned.redacted_because`, typically with empty `content`) through sync, history or a single-event fetch SHALL become a message, with the redacted content described in Message content. It SHALL be marked `was_redacted` and carry no attachment, exactly like a message redacted live. When `redacted_because` has no sender, the content is `[Redacted]`.

#### Scenario: Already redacted on the server
- **WHEN** an `m.room.message` arrives through sync or history with empty `content` and `unsigned.redacted_because.sender` = `@mod:s`, sent by `@a:s`
- **THEN** a message is added with content `[Redacted by <@mod:s display name>]` and `was_redacted` set

#### Scenario: Redacted by its author on the server
- **WHEN** an `m.room.message` from `@a:s` arrives with empty `content` and `unsigned.redacted_because.sender` = `@a:s`
- **THEN** a message is added with content `[Redacted]` and `was_redacted` set

#### Scenario: Empty content without redaction
- **WHEN** an `m.room.message` arrives with no `content.body` and no `unsigned.redacted_because`
- **THEN** no message is added

### Requirement: Server-redacted messages are not activity
A server-redacted message SHALL NOT update the room's last or unread activity. It is also not used as desktop-notification text (see `desktop-notifications`).

#### Scenario: Not activity
- **WHEN** a server-redacted message from another user arrives after message `$a`
- **THEN** the room's last and unread activity stay at `$a`

### Requirement: Replies to redacted messages
When the asynchronously fetched replied event carries `unsigned.redacted_because`, it SHALL fill the reply as a redacted message (see Message content) and SHALL NOT be treated as unavailable, even though its `content` is empty. A bundled `m.replace` on a redacted fetched event SHALL be ignored.

#### Scenario: Reply to a redacted message
- **WHEN** the fetched replied event has empty `content` and `unsigned.redacted_because`
- **THEN** the reply keeps its `replying_to`, whose content is `[Redacted]` or `[Redacted by <name>]` and which is marked `was_redacted`

#### Scenario: Replied event unavailable
- **WHEN** the fetch fails, or returns an event with no `content` and no `unsigned.redacted_because`
- **THEN** the reply has no `replying_to`

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

#### Scenario: Live member event replaces a fetched display name
- **WHEN** the display name `Bob Global` of `@bob:s` was learned from `GET /profile`, and a sync then delivers a `join` for `@bob:s` with displayname `Bob Room` and a server timestamp older than the fetch
- **THEN** the display name of `@bob:s` is `Bob Room`

#### Scenario: Sync still applies state
- **WHEN** a history page delivers `m.room.name` `Old`, and a sync then delivers `m.room.name` `New`
- **THEN** the room name is `New`

### Requirement: Edits carry attachments
When an applied `m.replace` edit has an `m.new_content` whose `msgtype` is an attachment type (image, video, audio, file or location) with an mxc `url` (or, for a location, a `geo_uri` of the form `geo:lat,lon` as defined in Attachments), the target message's attachment SHALL become the one it describes, built as for a normal message of that type. This SHALL hold for live, pending and embedded (`unsigned["m.relations"]["m.replace"]`) edits.

#### Scenario: Notice edited into a video
- **WHEN** an `m.notice` message `$n` from `@alice:s` is edited by `@alice:s` with `m.new_content` of `msgtype` `m.video`, `url` `mxc://s/vid`, `filename` `video.mp4` and `info` `{duration: 12000, w: 480, h: 864, size: 2726771, mimetype: "video/mp4"}`
- **THEN** message `$n` has a video attachment with that url, duration, size and mimetype, and its content is the edit's `body`

#### Scenario: Edit embedded in the original event
- **WHEN** the original event arrives with an `unsigned["m.relations"]["m.replace"]` from the same sender whose `m.new_content` is a video
- **THEN** the message has the video attachment

#### Scenario: Pending edit with an attachment
- **WHEN** an edit with a video `m.new_content` arrives before its target, and the target then arrives from the same sender
- **THEN** the target has the video attachment

### Requirement: Edits keep or ignore attachments
An edit whose `m.new_content` has no attachment MUST leave the target's existing attachment unchanged. An edit that is ignored (other sender, state target, redacted target, older edit) MUST NOT change the attachment.

#### Scenario: Text edit keeps the attachment
- **WHEN** a message with an image attachment is edited with a plain `m.text` `m.new_content`
- **THEN** the message shows the new text and keeps its image attachment

#### Scenario: Ignored edit does not add an attachment
- **WHEN** `@mallory:s` sends an `m.replace` with a video `m.new_content` for a text message from `@alice:s`
- **THEN** the message has no attachment

### Requirement: Location messages have an attachment
A message with `msgtype` `m.location` and a `geo_uri` of the form `geo:lat,lon` (as defined in Attachments) SHALL have a location attachment, even though it has no `url`.

#### Scenario: Regular location message
- **WHEN** a message with `msgtype` `m.location` and `geo_uri` `geo:1.5,2.5` arrives
- **THEN** it has a location attachment whose url is `https://maps.google.com/?q=1.5,2.5`

#### Scenario: Message edited into a location
- **WHEN** a text message is edited by its sender with an `m.new_content` of `msgtype` `m.location` and `geo_uri` `geo:1.5,2.5`
- **THEN** the message has the location attachment
