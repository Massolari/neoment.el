# Tasks

## 1. Reject invalid edits

- [ ] 1.1 Add `neoment-events--same-sender-p (a b)` to `neoment-events.el`, returning non-nil only when A is a string and `equal` to B. Verify with an ERT test in `test/neoment-events-test.el`: `("@a:s" "@a:s")` → t, `("@a:s" "@b:s")` → nil, `(nil nil)` → nil.
- [ ] 1.2 Give `neoment-events-test-edit` an optional SENDER argument passed as `:sender` (default stays `@alice:s`). Verify that the existing `neoment-events-edits` test still passes with `make test`.
- [ ] 1.3 In the `m.replace` branch of `neoment-events--handle-message`, add a `cond` clause after `(null target)` that returns nil when `(neoment-message-is-state target)` is set or when the edit's `sender` does not pass `neoment-events--same-sender-p` against `(neoment-message-sender target)`. Verify with a new ERT test `neoment-events-edits-foreign-sender`: a message `hello` from `@alice:s` plus an edit from `@mallory:s` with body `hacked` leaves the content `hello`, the id `$m` and `edit-data` nil, and `neoment-events-handle-multiple` returns nil for the edit batch.
- [ ] 1.4 Extend that test with the pending case (edit from `@mallory:s` first, then the target from `@alice:s`: original content shown, and `(gethash target-id (neoment-room-pending-events room))` is nil afterwards) and the embedded case (`unsigned.m.relations.m.replace` from `@mallory:s`: original content shown). Verify with `make test`.
- [ ] 1.5 Add an ERT test for a state target: a membership event (`neoment-events-test-member`) followed by an `m.replace` of its event id from the same sender leaves the state message's content unchanged. Verify with `make test`. Also check that the existing same-sender cases in `neoment-events-edits` (live, pending, embedded) still pass.

## 2. Reply fetch uses only same-sender replacements

- [ ] 2.1 In `neoment-events--event-message-fields`, use the bundled `m.replace` only when `neoment-events--same-sender-p` holds between its `sender` and the event's `sender`. Otherwise build the message from the original event. Verify with a new ERT test modeled on the existing reply-fetch test (around `test/neoment-events-test.el:475`): fetched event from `@bob:s` with body `question` and a bundled replacement from `@mallory:s` with new body `hacked` → the replied message has sender `@bob:s` and content `question`. The existing same-sender case (`q2`) still passes with `make test`.

## 3. Redacting a foreign edit keeps the message

- [ ] 3.1 In the `m.replace` branch of `neoment-events--handle-redaction`, remove the target message from `neoment-room-messages` only when that message exists and `neoment-events--same-sender-p` holds between the redacted edit's `sender` and the message's sender. Still clear the edit event's content. Return nil when the message was left in place. Verify with a new ERT test: a message from `@alice:s`, an edit of it from `@mallory:s`, then a redaction of that edit from `@mallory:s` → `(neoment-room-get-message room "$m")` still exists with content `hello`. Also check that redacting a same-sender edit still removes the message, as `neoment-events-redactions` expects. Verify with `make test`.

## 4. Integration check

- [ ] 4.1 Run the full `make` (compile with warnings as errors, lint, test) and verify it is green.

## Workflow follow-up

- Close issue #15 from the PR that implements this change.
- Archive the change after review. The archive adds "Edit validation" to `openspec/specs/matrix-events/spec.md` and updates its Replies and Redactions requirements.
