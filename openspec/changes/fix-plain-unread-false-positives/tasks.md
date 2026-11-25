# Tasks

## 1. Unread activity

- [ ] 1.1 Add the `unread-activity` slot to the room struct in `neoment-client.el`, and add `neoment-room-set-unread-activity`, which reuses the monotonic timestamp/age rule of `neoment-room-set-last-activity` (factor the comparison into a shared helper). Verify that the existing `neoment-client-ordering-and-last-activity` test still passes and that a new test proves the same tie rule for unread activity.
- [ ] 1.2 In `neoment-events--handle-message` (`neoment-events.el`), update unread activity next to last activity only when the message has no `thread-root-id` and its sender is not `(neoment-user-id)`. Verify with new tests in `test/neoment-events-test.el`. An own message and another user's thread reply each move last activity but not unread activity. Another user's main-timeline message moves both.

## 2. Order-based unread rule

- [ ] 2.1 Add a helper in `neoment-client.el` that returns an event's timestamp from `neoment-room-find-message` or the raw `events` table (`origin_server_ts`), or nil when the event isn't loaded. Verify with a test that covers a message, a raw state event and an unknown id.
- [ ] 2.2 Rewrite `neoment-room-unread-p` per design decision 2. A marker covers the unread activity when it has the same id, or when its timestamp (the loaded event's, else the receipt's `ts` for the receipt only) is >= the activity timestamp. Update `neoment-client-unread-rule` in `test/neoment-events-test.el` to set `unread-activity`, and add one test per scenario in the delta spec's "Unread rule": same event, receipt on a later loaded state event, unloaded receipt with a later `ts`, older receipt, unloaded `fully_read`, no unread activity, and manually marked unread. Verify that `make test` passes.

## 3. Room list and read marking

- [ ] 3.1 Update the `neoment-rooms-test-room` helper in `test/neoment-rooms-test.el` to set `unread-activity` along with `last-activity`, and update `neoment-room-mark-read` in `test/neoment-room-test.el` to set it too. Verify that every existing room-list sorting, badge and mark-read test passes unchanged in intent.
- [ ] 3.2 Add room-list tests in `test/neoment-rooms-test.el` for each case in issue #7: a receipt moved by another client to a later event shows no `•` and sorts among read rooms; an own message as the newest activity shows no `•`; another user's thread reply as the newest activity shows no `•` but still moves the room to the top of its group by recency. Verify with `make test`.
- [ ] 3.3 Add a test that `neoment-room-mark-read` sends no read markers when the only activity after the receipt is the user's own message or a thread reply, and still sends them (targeting the last activity id) when main-timeline activity from another user is unread. Verify with `make test`.

## 4. Cache

- [ ] 4.1 Save `unread_activity` in `neoment-storage--room-to-json` and restore it in `neoment-storage--room-from-json`, falling back to `last_activity` when it is missing or null. Verify with a round-trip test (unread activity that differs from last activity is preserved) and a test that a cache without the key restores unread activity equal to last activity.

## 5. Integration

- [ ] 5.1 Run `make compile lint test` and confirm that all three pass with no new warnings.

## Workflow follow-up

- Close issue #7 when the change lands.
- Archive the change after review, so the `matrix-events` and `session-management` specs are updated.
