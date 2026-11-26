# Spec Delta

## MODIFIED Requirements

### Requirement: Edits
An `m.replace` relation SHALL change the target's content to `m.new_content`, set `edit_data = {id: target, timestamp}` and change the message's id to the edit event id, keeping the original key. This happens only if the edit is newer than the last one applied. Edits to unknown targets SHALL be pending. Edits embedded in `unsigned["m.relations"]["m.replace"]` SHALL be processed too. An edit whose target has `was_redacted` set MUST be ignored, whatever order the events arrive in.

#### Scenario: Older edit ignored
- **WHEN** an edit with ts 100 arrives after an edit with ts 200 was applied
- **THEN** the content stays at the ts-200 version

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
`m.room.redaction` of an unknown target SHALL be pending. A target that is already redacted is ignored. Redacting an edit event SHALL remove the edited message entry, unless that message is redacted. Redacting a normal message SHALL set content `[Redacted]` (or `[Redacted: <reason>]`) and `was_redacted`, and clear any applied edit (`edit_data` and the edit's id). Redacting a reaction SHALL remove it, and delete the key when its list becomes empty.

#### Scenario: Redact last reaction
- **WHEN** the only 👍 reaction on a message is redacted
- **THEN** the message has no `👍` key

#### Scenario: Redaction after an edit
- **WHEN** message `$s` is edited by `$e` and then `$s` is redacted
- **THEN** `$s` shows `[Redacted]`, its id is `$s` and it has no `edit_data`

#### Scenario: Redacting an ignored edit
- **WHEN** `$s` is redacted, an edit `$e` of `$s` is ignored, and then `$e` is redacted
- **THEN** `$s` is still in the room with its redaction text
