# Tasks

## 1. Redact sticker targets

- [ ] 1.1 Add a regression test `neoment-events-redact-sticker` to `test/neoment-events-test.el`: handle an `m.sticker` event `$st` (body `s`, `url` `mxc://s/st`), then a redaction of `$st` with reason `oops`. Assert that the handler returns non-nil and that the message has content `[Redacted: oops]`, `was_redacted` set, and no attachment. Verify it fails on the current code with `make test`.
- [ ] 1.2 Add a regression test `neoment-events-pending-redaction-of-sticker`: a redaction of unknown `$st` first, then sticker `$st`. Assert content `[Redacted]`, `was_redacted` set, and no attachment.
- [ ] 1.3 In `neoment-events--handle-redaction` (`neoment-events.el`), make the `m.room.message` target branch also match `m.sticker` (e.g. `(member (alist-get 'type target) '("m.room.message" "m.sticker"))`), so stickers share the message path, including the edit-removal logic. Verify that both new tests and the whole suite pass with `make test`.
- [ ] 1.4 Run `make compile lint` and verify there are no new warnings.

## Workflow follow-up

- Close issue #20 when the fix is merged (e.g. `Fixes #20` in the PR).
- Archive the change after review.
