# Spec Delta

## ADDED Requirements

### Requirement: Cached message key
The cached message SHALL be keyed by its effective id (the original event id, also for an edited message). Loading the cache SHALL store each message under the effective id of the loaded message, whatever key the file uses, so caches written with an edit's id as key load correctly.

#### Scenario: Edited last message survives a restart
- **WHEN** a room whose last message `$o` was edited by `$oe` is saved and loaded again
- **THEN** the cached message is keyed by `$o`, the loaded room finds it by `$o`, and it keeps its edited content and `edit_data`

#### Scenario: Cache written with the edit's id as key
- **WHEN** `cache.json` holds a message under the key `$oe` whose `edit_data.id` is `$o`
- **THEN** the loaded room stores the message under `$o`
