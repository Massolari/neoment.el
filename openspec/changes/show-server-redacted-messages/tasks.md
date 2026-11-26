# Tasks

## 1. Keep server-redacted messages in the timeline

- [ ] 1.1 Add `neoment-events--redacted-p (event)` in `neoment-events.el`, returning non-nil when `unsigned.redacted_because` is present. Reuse it in `neoment-events-event-to-message` in place of the inline check. Verify with the existing `[Redacted by Mod]` / `[Redacted]` assertions in `test/neoment-events-test.el`, which must still pass.
- [ ] 1.2 In `neoment-events-event-to-message`, set `:was-redacted t` for redacted events and give them no attachment, even when `content.url` is present. Verify with a test where a redacted `m.image` that still has a `url` yields a message with `was-redacted` set and no attachment.
- [ ] 1.3 In `neoment-events--handle-message`, change the body guard so an event is ignored only when it has no string `content.body` **and** is not redacted. Verify with new ERT cases that cover the three scenarios of the "Server-redacted messages" requirement:
  - `content` nil + `redacted_because.sender` = `@mod:s` adds `[Redacted by Mod]` with `was-redacted`.
  - Same-sender redaction adds `[Redacted]`.
  - Empty content without `redacted_because` adds nothing.
- [ ] 1.4 Add an ERT case that a server-redacted message delivered as history (`is-history` non-nil) is added. Also check that a later `m.room.redaction` targeting it returns nil and leaves its content unchanged, since it is already redacted. Run `make test` and confirm the suite passes.

## 2. Keep the quote when replying to a redacted message

- [ ] 2.1 In the fetch callback of `neoment-events--reply-to`, treat the fetched event as available when it has `content` **or** `neoment-events--redacted-p` is true. Verify with a new ERT case modelled on `neoment-events-async-reply`, in which the callback returns `(content . nil)` with `unsigned.redacted_because`. The reply must keep `replying-to`, and its content must be `[Redacted…]` with no placeholder.
- [ ] 2.2 Make `neoment-events--fill-message` copy `was-redacted` from the source message. Verify in the same test that the filled replied message has `was-redacted` set.
- [ ] 2.3 Add an ERT case where the fetch returns an event with no `content` and no `redacted_because`, and assert that the reply loses `replying-to`. This guards the "Replied event unavailable" scenario.

## 3. Integration check

- [ ] 3.1 Run `make all` (compile, lint, test) and confirm it finishes without byte-compile warnings, lint errors or test failures.

## Workflow follow-up

- Close issue #17 with the PR.
- Archive the change after review, so the `matrix-events` spec picks up the delta.
