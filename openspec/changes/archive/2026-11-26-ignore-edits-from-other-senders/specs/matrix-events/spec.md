# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

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

### Requirement: Redactions
`m.room.redaction` of an unknown target SHALL be pending. A target that is already redacted is ignored. Redacting an edit event SHALL remove the edited message entry, but only when the edit's sender matches the edited message's sender and the edited message is not a state message. Redacting an edit from another sender, or an edit of a state message, MUST leave the message unchanged. Redacting a normal message SHALL set content `[Redacted]` (or `[Redacted: <reason>]`) and `was_redacted`. Redacting a reaction SHALL remove it, and delete the key when its list becomes empty.

#### Scenario: Redact last reaction
- **WHEN** the only 👍 reaction on a message is redacted
- **THEN** the message has no `👍` key

#### Scenario: Redact a foreign edit
- **WHEN** `@mallory:s` sends an `m.replace` of a message from `@alice:s` and then redacts that edit
- **THEN** the message from `@alice:s` is still in the room with its original content

#### Scenario: Redact an edit of a state message
- **WHEN** `@alice:s` sends an `m.replace` of her own membership event and then redacts that edit
- **THEN** the membership event is still in the room with its original content
