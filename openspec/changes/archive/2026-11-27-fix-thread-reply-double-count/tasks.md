# Tasks

## 1. Regression tests (failing first)

- [x] 1.1 In `test/neoment-events-test.el`, add `neoment-events-thread-same-batch-not-double-counted`: one `neoment-events-handle-multiple` call (live) with root `$r` (`unsigned.m.relations.m.thread.count` 2) and two `m.thread` replies to `$r`, with later ts. Assert the count is 2. Verify it fails on current code (count 4), with `make test`.
- [x] 1.2 Add `neoment-events-thread-history-not-double-counted`: the same events through `neoment-events-handle-multiple` with `is-history` t. Assert the count stays 2. Also cover replies loaded in a first history call and root `$r` (count 2) in a second call: the count is 2. Verify the first case fails on current code.

## 2. Fix the increment condition

- [x] 2.1 In `neoment-events.el`, add a dynamic variable (e.g. `neoment-events--batch-ids`, default nil) holding the ids of messages stored in the current batch. Bind it to a fresh hash set in `neoment-events-handle-multiple`, only when it is not already bound, so recursive calls for pending events share the outer batch. Verify by byte-compiling cleanly with `make compile`.
- [x] 2.2 In `neoment-events--handle-message`, record in the batch set (when bound) the id of each stored message that carries a server thread count. Increment the root's `thread-replies-count` only when the root id is not in the batch set (review: no `is-history` check, so roots without a server count still count locally; covered by `neoment-events-thread-root-without-server-count` and `neoment-events-thread-history-root-then-live-reply`). Update the docstrings to say so. Verify the tests from 1.1 and 1.2 pass with `make test`.
- [x] 2.3 Update `neoment-events-threads` so the root and the live reply arrive in separate batches (root first, then the reply in a later `neoment-events-handle` / `-handle-multiple` call), and keep asserting 2 → 3. Verify with `make test`. This is the spec's "New thread reply" scenario.

## 3. Integration check

- [x] 3.1 Run `make compile lint test` and verify everything passes with no new warnings.

## Workflow follow-up

- Close issue #14 when the fix is merged.
- Archive the change after review.
