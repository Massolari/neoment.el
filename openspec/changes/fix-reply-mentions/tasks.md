# Tasks

## 1. Stop inheriting mentions on received replies

- [x] 1.1 In `neoment-events--reply-to` (`neoment-events.el`), remove the `append` of the replied message's mentions in the cached-entry branch and in the async fetch callback's `waiting` loop. Keep placeholder filling, the waiting list and the unavailable-reply cleanup unchanged. Verify `make compile` passes with no warnings.
- [x] 1.2 Add ERT tests in `test/neoment-events-test.el` for the three new `matrix-events` scenarios (loaded replied message with `@me:s` mention → reply mentions empty; fetched replied message → reply keeps exactly `("@carol:s")`; reply to own message without `m.mentions` → empty). Verify they fail before 1.1 and pass with `make test`.

## 2. Mention the replied-to sender on outgoing replies

- [x] 2.1 Add a `:reply-sender` keyword to `neoment-compose-message-content` and `neoment-compose-send` (`neoment-compose.el`). Merge it after body mentions without duplicates, skip it when nil or equal to `(neoment-user-id)`, and emit `m.mentions` when the merged list is non-empty. Update both docstrings. Verify `make compile` passes.
- [x] 2.2 In `neoment-compose-send-and-close`, pass `:reply-sender (neoment-message-sender message)` only when the relation type is `reply`. Verify by reading the call site, and with test 2.3.
- [x] 2.3 Add ERT tests in `test/neoment-compose-test.el` for the five `message-compose` scenarios (sender only, merged with body mention, already mentioned, own message → no `m.mentions`, thread without reply → no `m.mentions`). Make sure the existing reply/thread/edit tests still pass. Verify with `make test`.

## 3. Integration check

- [x] 3.1 Run `make all` (compile, lint, test) and verify it passes cleanly.

## Workflow follow-up

- Reference issue #27 in the PR so it closes on merge.
- Archive the change after review, syncing the `matrix-events` and `message-compose` specs.
