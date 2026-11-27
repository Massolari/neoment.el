# Spec Delta

## MODIFIED Requirements

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
