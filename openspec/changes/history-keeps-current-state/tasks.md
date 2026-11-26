# Tasks

## 1. Room metadata from history

- [x] 1.1 Add a failing ERT test to `test/neoment-events-test.el` (inside `neoment-events-test`) that reproduces issue #13. Apply `m.room.name` "New" at ts 2000 without history, then `neoment-events-handle-multiple` an older "Old" at ts 100 with `is-history` = t. Assert that `neoment-room-name` is "New". Verify with `make test` that it fails before the fix.
- [x] 1.2 Add tests that do the same for `m.room.topic`, `m.room.avatar`, `m.room.tombstone` (no tombstone before, still nil after) and `m.space.child` (`!child:s` not in `space_rooms`), following the scenarios in `specs/matrix-events/spec.md`.
- [x] 1.3 In `neoment-events-handle` (`neoment-events.el`), wrap the `setf` in the `m.room.name`, `m.room.topic`, `m.room.avatar` and `m.room.tombstone` branches in `(unless is-history …)`, and the `m.space.child` add the same way. Keep the return values as they are. Verify that tests 1.1 and 1.2 pass with `make test`.
- [x] 1.4 Update the `neoment-events-handle` docstring so it says that IS-HISTORY also keeps current room state unchanged. Verify that `make lint` (checkdoc) is clean.

## 2. Canonical alias from history

- [x] 2.1 Add tests for the two history alias scenarios. In the first, aliases stay `#new:s` and the `set the room aliases to #old:s` state message is in the room. In the second, an unnamed room keeps its id as its name. Verify with `make test` that they fail first.
- [x] 2.2 Add an `is-history` argument to `neoment-events--handle-canonical-alias`, pass it from `neoment-events-handle`, and skip the `aliases` and name `setf`s when it is non-nil while still adding the state message. Update the docstring. Verify that the 2.1 tests pass.

## 3. Membership from history

- [x] 3.1 Add tests for an old `leave` in history (member stays, "left the room" message is present) and an old `join` in history (non-member stays out, "joined the room" message is present). Also add one test that a newer display name isn't replaced by an older one from history. Verify with `make test` that the member tests fail first.
- [x] 3.2 In the `m.room.member` branch of `neoment-events-handle`, skip the `puthash`/`remhash` on `neoment-room-members` when `is-history` is non-nil, and keep building and adding the membership message. Verify that the 3.1 tests pass.

## 4. Integration check

- [x] 4.1 Run the full suite with `make test`, then run `make compile` and `make lint`. Confirm that everything passes, including the existing `/sync` and refresh-state tests in `test/neoment-sync-test.el` and `test/neoment-rooms-test.el`, which must keep applying state.

## Workflow follow-up

- Archive the change and sync the `matrix-events` spec after review.
- Reference issue #13 in the PR so that merging closes it.
