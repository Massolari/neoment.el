# Spec Delta

## MODIFIED Requirements

### Requirement: Edits
An `m.replace` relation SHALL change the target's content to `m.new_content`, set `edit_data = {id: target, timestamp}` and change the message's id to the edit event id, keeping the original key. This happens only if the edit is newer than the last one applied. Edits to unknown targets SHALL be pending. Edits embedded in `unsigned["m.relations"]["m.replace"]` SHALL be processed too. A room SHALL always store a message under its effective id (the original event id), never under the id of an edit.

#### Scenario: Older edit ignored
- **WHEN** an edit with ts 100 arrives after an edit with ts 200 was applied
- **THEN** the content stays at the ts-200 version

#### Scenario: Edited message found by its original id
- **WHEN** message `$o` is edited by `$oe`
- **THEN** the message is stored under the key `$o`, not `$oe`, and a reaction to `$o` is applied to it

### Requirement: Room tracking
A room SHALL be tracked while its buffer is open. An untracked room keeps only its last non-state message and drops events. Opening a buffer SHALL start tracking, clear messages and reload history. Closing it SHALL stop tracking, keep only the last message, and clear `events`, `pending_events` and `prev_batch`. The kept message SHALL stay stored under its effective id, so relations that target it still apply after the buffer is closed.

#### Scenario: Untracked room receives messages
- **WHEN** an untracked room receives 3 messages in one sync
- **THEN** only the newest non-state message is kept

#### Scenario: Closing a buffer keeps an edited message under its original id
- **WHEN** the last message `$o` was edited by `$oe` and the room buffer is closed
- **THEN** the only kept message is stored under `$o`, and a later reaction to `$o` is applied to it instead of going pending
