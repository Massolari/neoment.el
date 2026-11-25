# Tasks

## 1. In-memory key (neoment-client.el)

- [ ] 1.1 In `test/neoment-events-test.el`, add a failing test: tracked room, message `$o`, edit `$oe`, `(neoment-room-set-tracked room nil)` → `(hash-table-keys (neoment-room-messages room))` is `("$o")`. Then handle a reaction to `$o`: it is applied to the message and `pending-events` is empty. Verify with `make test` that it fails on the current code (keys come back as `("$oe")`).
- [ ] 1.2 In `neoment-room-set-tracked` (close branch), put the last message back under `(neoment-message-effective-id last)`. Verify the 1.1 test passes.
- [ ] 1.3 In `neoment-room-add-message`, key both the tracked and the untracked branch by `neoment-message-effective-id`. Add a test that calls `add-message` on an untracked room with an already-edited message (`:id "$oe" :edit-data (:id "$o" …)`) and checks that the key is `"$o"`. Verify with `make test`.
- [ ] 1.4 Extend `neoment-events-edits` (or add a test next to it) to assert that the message stays stored under `"$m"` and that `(neoment-room-get-message room "$e2")` is nil after the edit. Verify with `make test`.

## 2. Cache key (neoment-storage.el)

- [ ] 2.1 Add a failing test next to `neoment-storage-cache-compact-room`: a room whose last message `$o` was edited by `$oe` goes through `neoment-storage-cache-json` → JSON encode/decode → `neoment-storage-load-cache-json`. The saved `messages` key is `$o`. The loaded room returns the message from `(neoment-room-get-message back "$o")` with the edited content and `edit_data`. Verify with `make test` that it fails before the fix.
- [ ] 2.2 In `neoment-storage--room-to-json`, key the cached message by `(neoment-message-effective-id last)`. Keep the message body's `id` as it is. Verify the save part of 2.1.
- [ ] 2.3 In `neoment-storage--room-from-json`, put each loaded message under `(neoment-message-effective-id msg)` and ignore the JSON key. Add a test that loads hand-built cache data with the key `$oe` and `edit_data.id` = `$o`, and checks that the message is stored under `$o`. Verify 2.1 and this test pass with `make test`.

## 3. Integration check

- [ ] 3.1 Run `grep -n "puthash (neoment-message-id" *.el` and verify no code that puts messages into the message table is left (only unrelated tables, if any). Run the full `make test` and `make lint` (or the project's byte-compile/lint target) and verify both are clean.

## Workflow follow-up

- Close issue #18 from the PR that lands this change.
- Archive the change after review, and sync the `matrix-events` and `session-management` deltas into the main specs.
