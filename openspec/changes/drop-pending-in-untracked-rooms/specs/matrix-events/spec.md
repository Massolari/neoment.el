# Spec Delta

## MODIFIED Requirements

### Requirement: Edits
An `m.replace` relation SHALL change the target's content to `m.new_content`, set `edit_data = {id: target, timestamp}` and change the message's id to the edit event id, keeping the original key. This happens only if the edit is newer than the last one applied. In a tracked room, edits to unknown targets SHALL be pending. In an untracked room, they SHALL be dropped (see Untracked rooms keep no pending events). Edits embedded in `unsigned["m.relations"]["m.replace"]` SHALL be processed too. A room SHALL always store a message under its effective id (the original event id), never under the id of an edit. An edit whose target has `was_redacted` set MUST be ignored, whatever order the events arrive in.

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

### Requirement: Redactions
In a tracked room, `m.room.redaction` of an unknown target SHALL be pending. In an untracked room, it SHALL never be pending (see Untracked rooms keep no pending events). A target that is already redacted is ignored. Redacting an edit event SHALL remove the edited message entry only when that edit was applied: the edit's sender matches the message's sender, and the message is neither a state message nor redacted. Otherwise the message MUST be left unchanged. Redacting a normal message SHALL set content `[Redacted]` (or `[Redacted: <reason>]`) and `was_redacted`, and clear any applied edit (`edit_data` and the edit's id). An `m.sticker` target SHALL be redacted exactly like an `m.room.message` target, and lose its attachment. Redacting a reaction SHALL remove it, and delete the key when its list becomes empty.

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
`m.reaction` with `m.annotation` SHALL add `{event_id, sender}` under `reactions[key]` of the target message. If the target is unknown, the reaction SHALL become pending in a tracked room and be dropped in an untracked room (see Untracked rooms keep no pending events).

#### Scenario: Two users react
- **WHEN** two users react 👍 to a message
- **THEN** `reactions["👍"]` has two entries

## ADDED Requirements

### Requirement: Untracked rooms keep no pending events
An untracked room SHALL never add to `pending_events`. An edit, reaction or redaction whose target is not the kept last message SHALL be dropped, and the room SHALL NOT be marked as changed. Its target cannot arrive until the buffer is opened, and opening the buffer reloads history, which delivers the relation again. Relations that target the kept message SHALL still apply.

#### Scenario: Untracked room drops relations to messages it does not keep
- **WHEN** an untracked room whose kept message is `$last` receives an edit, a reaction and a redaction, each targeting the older message `$old`
- **THEN** `pending_events` stays empty, `$last` is unchanged, and the room is not marked as changed

#### Scenario: Untracked room applies an edit to its kept message
- **WHEN** an untracked room whose kept message is `$last` receives an edit of `$last` from its sender
- **THEN** `$last` shows the edited content and `pending_events` stays empty

#### Scenario: Untracked room redacts its kept message
- **WHEN** an untracked room whose kept message is `$last` receives a redaction of `$last`
- **THEN** `$last` shows `[Redacted]`, has `was_redacted` set, and `pending_events` stays empty

#### Scenario: Opening the room after dropped relations
- **WHEN** an untracked room dropped a reaction to `$old`, and the buffer is then opened and history delivers `$old` and that reaction
- **THEN** `$old` has the reaction exactly once
