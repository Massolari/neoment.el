# Spec Delta

## MODIFIED Requirements

### Requirement: Reply and thread relations
A reply SHALL add `m.relates_to.m.in_reply_to.event_id = <effective id>`. A thread message SHALL set `m.relates_to = {rel_type:"m.thread", event_id:<root>, is_falling_back:true}`. When it is a reply it SHALL instead set `m.in_reply_to` and omit `is_falling_back`. A reply SHALL add the replied message's sender to `m.mentions.user_ids` (after any body mentions, without duplicates), unless that sender is the current user. An edit of a reply SHALL keep that sender in `m.new_content.m.mentions` when the replied message is loaded, and SHALL NOT add it to the top-level `m.mentions`.

#### Scenario: Reply to edited message
- **WHEN** replying to a message that was edited
- **THEN** `in_reply_to.event_id` is the original event id

#### Scenario: Reply mentions the replied-to sender
- **WHEN** the user replies `ok` to a message from `@bob:s`
- **THEN** `m.mentions.user_ids` is `["@bob:s"]`

#### Scenario: Reply sender merged with body mentions
- **WHEN** the user replies `hi @alice:s` (known display name) to a message from `@bob:s`
- **THEN** `m.mentions.user_ids` is `["@alice:s", "@bob:s"]`

#### Scenario: Replied-to sender already mentioned
- **WHEN** the user replies `hi @bob:s` (known display name) to a message from `@bob:s`
- **THEN** `m.mentions.user_ids` is `["@bob:s"]`

#### Scenario: Reply to own message
- **WHEN** the user replies `ok` to their own message
- **THEN** the content has no `m.mentions`

#### Scenario: Thread message without reply
- **WHEN** the user sends `ok` in a thread without replying to a message
- **THEN** the content has no `m.mentions`

#### Scenario: Reply inside a thread
- **WHEN** the user replies `ok` to a message from `@bob:s` inside a thread
- **THEN** `m.relates_to` has `m.in_reply_to` and no `is_falling_back`, and `m.mentions.user_ids` is `["@bob:s"]`

#### Scenario: Edit of a reply
- **WHEN** the user edits their reply to a loaded message from `@bob:s`
- **THEN** `m.new_content.m.mentions.user_ids` is `["@bob:s"]` and the top-level content has no `m.mentions`
