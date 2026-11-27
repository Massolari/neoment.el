# Tasks

## 1. Tests for untracked rooms (written first, expected to fail)

- [x] 1.1 In `test/neoment-events-test.el` (section 3.8 Tracking), add an ERT test (`neoment-events-untracked-drops-unknown-relations`, issue #19). It closes the buffer of a room so its kept message is `$last`, then delivers an edit (`neoment-events-test-edit`), an `m.reaction` and an `m.room.redaction`, each targeting `$old`. It asserts that `pending_events` is empty, that `$last` is unchanged, and that `neoment-events-handle-multiple` returns nil. Run `make test` and confirm that the edit and reaction assertions fail before the fix.
- [x] 1.2 Add an ERT test for an untracked edit of the kept message: an edit of `$last` from its sender updates its content, and `pending_events` stays empty. Add another for an untracked redaction of `$last`: it shows `[Redacted]`, has `was_redacted` set, and `pending_events` stays empty. Verify both pass with `make test`. They cover behavior that already exists, as regression guards.
- [x] 1.3 Add an ERT test for opening the room after a dropped reaction. A reaction to `$old` is dropped while the room is untracked, then `neoment-room-set-tracked room t` runs and a history batch (`is-history` t) delivers `$old` and the same reaction. Assert that `$old` has that reaction exactly once. Verify with `make test`.

## 2. Implementation

- [x] 2.1 In `neoment-events.el`, make `neoment-events--add-pending` return without storing when `(neoment-room-is-tracked room)` is nil. Update its docstring to say that an untracked room keeps no pending events, because the target is not kept and history delivers the event again on open. Leave the tracked check in `neoment-events--handle-redaction` as is (it picks the untracked branch). Verify that the tests from group 1 and the full suite pass with `make test`.
- [x] 2.2 Run `make compile lint` and verify there are no byte-compile warnings and no lint errors.

## 3. Spec

- [x] 3.1 Run `openspec validate drop-pending-in-untracked-rooms` and verify that it passes. Under `--strict`, the only warnings left are the length warnings on the existing Edits and Redactions requirements, which were already over 500 characters before this change.

## Workflow follow-up

- Close issue #19 from the PR description.
- Archive the change and sync the `matrix-events` spec after review.
