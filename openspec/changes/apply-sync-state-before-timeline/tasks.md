# Tasks

## 1. Regression tests (red)

- [x] 1.1 In `test/neoment-sync-test.el`, add `neoment-sync-timeline-state-overrides-state-block`: one `neoment-sync-process` call with a limited joined room `!r:s` whose `state.events` has `m.room.name` `Old` (ts 100) and whose `timeline.events` has `m.room.name` `New` (ts 2000). Assert `(neoment-room-name room)` is `"New"`. Verify with `make test` that it fails on the current code (name is `"Old"`).
- [x] 1.2 Add `neoment-sync-timeline-join-overrides-state-leave`: `state.events` has `m.room.member` `@bob:s` `leave` (ts 100) and `timeline.events` has `@bob:s` `join` (ts 2000). Assert `@bob:s` is in `(neoment-room-members room)`. Verify it fails on the current code.
- [x] 1.3 Add `neoment-sync-state-block-alone-applies`: `state.events` has `m.room.topic` `Hello` and the timeline has no topic event. Assert the topic is `"Hello"`. This one passes before and after the fix, as a guard against dropping the state block.

## 2. Fix the processing order

- [x] 2.1 In `neoment-sync--process-joined` (`neoment-sync.el`), move the `neoment-events-handle-multiple` call for `state.events` before the `let` that binds `neoment-events--timeline-limited` around the timeline call. Keep the state call outside that binding and leave the rest of the order unchanged. Verify tests 1.1–1.3 pass, and so do `neoment-sync-limited-thread-reply-marks-unread` and `neoment-sync-thread-reply-without-gap-stays-read`, unchanged.
- [x] 2.2 Update the docstring or comment near the calls to say that the state block is applied first because it describes the room before the timeline. Verify that `make lint` reports no new warnings.

## 3. Integration check

- [x] 3.1 Run `make test`, `make compile` and `make lint` and verify that all three succeed with no failures or byte-compile warnings.

## Workflow follow-up

- Reference issue #48 in the commit / PR ("Fixes #48").
- Archive the change and sync the `matrix-sync` spec after review.
