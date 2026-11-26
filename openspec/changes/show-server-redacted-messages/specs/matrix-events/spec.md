# Spec Delta

## MODIFIED Requirements

### Requirement: Message content
`m.room.message` and `m.sticker` events without `content.body` SHALL be ignored, unless they carry `unsigned.redacted_because` (see Server-redacted messages). The message content is `body`. `formatted_content` is `formatted_body` when the format is `org.matrix.custom.html` and it is not `"* "`. `m.new_content` overrides both. Mentions come from `m.mentions.user_ids`. A redacted event (`unsigned.redacted_because`) shows `[Redacted]`, or `[Redacted by <name>]` when the redactor is not the author.

#### Scenario: Redacted by moderator
- **WHEN** a message's `redacted_because.sender` differs from the author
- **THEN** its content is `[Redacted by <moderator name>]`

## ADDED Requirements

### Requirement: Server-redacted messages
A message event that arrives already redacted (`unsigned.redacted_because`, typically with empty `content`) through sync, history or a single-event fetch SHALL become a message, with the redacted content described in Message content. It SHALL be marked `was_redacted` and carry no attachment, exactly like a message redacted live. It SHALL NOT update the room's last or unread activity, and SHALL NOT be used as desktop-notification text (neither as the candidate nor as the stored-message fallback). When `redacted_because` has no sender, the content is `[Redacted]`.

#### Scenario: Not activity
- **WHEN** a server-redacted message from another user arrives after message `$a`
- **THEN** the room's last and unread activity stay at `$a`

#### Scenario: Not notification text
- **WHEN** one sync brings Bob's message `hi` and then a later server-redacted message, and the notification count rises
- **THEN** the desktop notification shows `hi`

#### Scenario: Already redacted on the server
- **WHEN** an `m.room.message` arrives through sync or history with empty `content` and `unsigned.redacted_because.sender` = `@mod:s`, sent by `@a:s`
- **THEN** a message is added with content `[Redacted by <@mod:s display name>]` and `was_redacted` set

#### Scenario: Redacted by its author on the server
- **WHEN** an `m.room.message` from `@a:s` arrives with empty `content` and `unsigned.redacted_because.sender` = `@a:s`
- **THEN** a message is added with content `[Redacted]` and `was_redacted` set

#### Scenario: Empty content without redaction
- **WHEN** an `m.room.message` arrives with no `content.body` and no `unsigned.redacted_because`
- **THEN** no message is added

### Requirement: Replies to redacted messages
When the asynchronously fetched replied event carries `unsigned.redacted_because`, it SHALL fill the reply as a redacted message (see Message content) and SHALL NOT be treated as unavailable, even though its `content` is empty. A bundled `m.replace` on a redacted fetched event SHALL be ignored.

#### Scenario: Reply to a redacted message
- **WHEN** the fetched replied event has empty `content` and `unsigned.redacted_because`
- **THEN** the reply keeps its `replying_to`, whose content is `[Redacted]` or `[Redacted by <name>]` and which is marked `was_redacted`

#### Scenario: Replied event unavailable
- **WHEN** the fetch fails, or returns an event with no `content` and no `unsigned.redacted_because`
- **THEN** the reply has no `replying_to`
