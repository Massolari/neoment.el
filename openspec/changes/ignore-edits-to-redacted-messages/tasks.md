# Tasks

## 1. Regression tests

- [x] 1.1 In `test/neoment-events-test.el`, add `neoment-events-edit-after-redaction`. Handle message `$s` ("secret"), then a redaction of `$s`, then `(neoment-events-test-edit "$e" "$s" "secret2" <later ts>)`. Assert that content is `"[Redacted]"`, `was-redacted` is t, the id is still `$s`, `edit-data` is nil, and `neoment-events-handle` on the edit returns nil. Verify with `make test` that it fails on the current code (content becomes `"secret2"`).
- [x] 1.2 In the same file, add `neoment-events-pending-redaction-then-history-edit`. Make the redaction of `$s` pending (target unknown). Then call `neoment-events-handle-multiple` with `is-history` non-nil on a page that holds `$s` and a later-ts edit of `$s`. Assert that content is `"[Redacted]"` and `was-redacted` is t. Verify with `make test` that it fails on the current code.
- [x] 1.3 Add `neoment-events-edit-of-event-redacted-on-arrival`: an event carrying `unsigned.redacted_because` followed by an edit of it. Assert content stays `"[Redacted]"`, `was-redacted` is t, the id is still `$s`, and the edit returns nil.

## 2. Fix

- [x] 2.1 In `neoment-events--handle-message` (`neoment-events.el`, the `m.replace` branch), add a `cond` clause right after the `(null target)` clause. When `(neoment-message-was-redacted target)` is non-nil, return nil without touching the message. Place it after the pending check so that edits to unknown targets still wait, and before the timestamp and `new-content` clauses so that nothing is written. Verify that `make test` passes, including both new tests and the existing `neoment-events-edits` and `neoment-events-redactions`.
- [x] 2.2 In `neoment-events-event-to-message`, set `:was-redacted` when the event carries `unsigned.redacted_because`, so the guard also covers events that arrive already redacted.
- [x] 2.3 Verify that `make compile` (byte-compile with warnings as errors) and `make lint` pass.

## 3. Spec

- [x] 3.1 Check that the delta in `specs/matrix-events/spec.md` matches the behavior that was built, and run `openspec validate ignore-edits-to-redacted-messages --strict`. Verify that it reports the change as valid.

## Workflow follow-up

- Archive the change (sync the `matrix-events` Edits requirement into the main spec) after review.
- Close issue #16 with the fix's commit or PR.
