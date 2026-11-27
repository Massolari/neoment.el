# Proposal

## Why

An untracked room (one with no open buffer) keeps only its last message and stores no raw events. Even so, every edit or reaction whose target is not that last message still goes into `pending_events`. In a busy room, that is almost every one. In an untracked room the target can never arrive: history is only loaded when the buffer opens, and the live timeline only moves forward. Only closing a buffer clears `pending_events`, so a room you never open grows this table without limit over a long session (issue #19).

Commit 6bcc683 already fixed the redaction half of #19. In an untracked room, a redaction now applies to the kept last message (or to its applied edit) and is never kept pending. Edits and reactions still need the same treatment.

## What Changes

- An untracked room SHALL never keep events in `pending_events`. An edit, reaction or redaction whose target is not the kept last message is dropped.
- Relations that target the kept last message keep working as they do today. An edit of it is applied, a reaction to it is attached and a redaction of it redacts it. This behavior is already in place and stays.
- Nothing is lost when the room is opened. Opening the buffer starts tracking and reloads history, which delivers the target messages together with their edits, reactions and redactions.
- Tracked rooms keep their current pending behavior.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `matrix-events`: The Edits, Reactions and Redactions requirements now say that an unknown target becomes pending only in a tracked room. A new requirement, "Untracked rooms keep no pending events", says that an untracked room drops relations whose target it does not keep. The Room tracking requirement is unchanged.

## Impact

- `neoment-events.el`: `neoment-events--add-pending` (or its callers in the edit, reaction and redaction branches) skips untracked rooms.
- `test/neoment-events-test.el`: new tests for edits and reactions in untracked rooms.
- No change to storage: the cache already writes an empty `pending_events`. No change to the API or the UI.
