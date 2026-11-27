# Spec Delta

## MODIFIED Requirements

### Requirement: Replies
An `m.in_reply_to` relation SHALL set `replying_to` to the replied message (id = `in_reply_to.event_id`). The replied event is fetched asynchronously if not loaded, using its `m.replace` replacement when there is one and its sender matches the replied event's sender. A replacement from another sender MUST be ignored and the original event shown. A reply's mentions SHALL be only its own `m.mentions.user_ids`. A relation with `is_falling_back: true` MUST NOT be treated as a reply.

#### Scenario: Thread fallback
- **WHEN** a thread message has `m.in_reply_to` with `is_falling_back: true`
- **THEN** it has no `replying_to`

#### Scenario: Async fetch
- **WHEN** the replied event is not loaded
- **THEN** the message renders with a placeholder reply, and the room re-renders once `GET /rooms/<r>/event/<id>` returns

#### Scenario: Fetched replacement from another sender
- **WHEN** the fetched replied event is from `@bob:s` with body `question`, and its bundled replacement is from `@mallory:s` with new body `hacked`
- **THEN** the reply quote shows sender `@bob:s` and content `question`

#### Scenario: Replied message's mentions are not inherited
- **WHEN** a reply with no `m.mentions` answers a loaded message whose `m.mentions.user_ids` is `["@me:s"]`
- **THEN** the reply's mentions are empty

#### Scenario: Fetched replied message's mentions are not inherited
- **WHEN** a reply with `m.mentions.user_ids` `["@carol:s"]` answers an unloaded message, and the fetched event has `m.mentions.user_ids` `["@me:s"]`
- **THEN** after the fetch the reply's mentions are exactly `["@carol:s"]`

#### Scenario: Reply to own message without explicit mention
- **WHEN** `@bob:s` replies to a message sent by `@me:s` and the reply has no `m.mentions`
- **THEN** the reply's mentions are empty
