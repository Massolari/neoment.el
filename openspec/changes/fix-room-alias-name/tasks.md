# Tasks

## 1. Joined rooms: derive the alias name instead of storing it

- [ ] 1.1 In `neoment-client.el` `neoment-room-display-name`, add the alias step for joined rooms between the explicit name and heroes: `name` ≠ id → `(car (neoment-room-aliases room))` → heroes → members → `Empty room` (design D2). Verify by extending `neoment-client-display-name-rules` in `test/neoment-events-test.el`: with aliases `("#dev:s" "#alt:s")` and heroes set, the display name is `#dev:s`, and once `name` is `dev` it is `dev`.
- [ ] 1.2 In `neoment-events.el` `neoment-events--handle-canonical-alias`, remove the `setf` of `neoment-room-name`, keeping the aliases update, the state message and the `is-history` guard (design D1). Update `neoment-events-canonical-alias` so it asserts that `neoment-room-name` stays the room id and the display name is `#a:s`, then becomes non-alias after the aliases are removed.
- [ ] 1.3 Add regression tests in `test/neoment-events-test.el` for issue #22, one per spec scenario: alias `#old:s` → `#new:s` gives display name `#new:s`; removing the aliases drops `#old:s`; an alias event on a room named `dev` keeps `dev`; an empty `m.room.name` on a room named `dev` with alias `#dev:s` gives `#dev:s`. Check that `neoment-events-invited-empty-name` (whose last assertion uses `room`) and `neoment-events-history-alias-keeps-unnamed-room` still pass unchanged. Run `make test` and confirm it passes.

## 2. Invited rooms: alias separate from name

- [ ] 2.1 Add an `alias` slot to `neoment-invited-room` in `neoment-client.el`. Make `neoment-events-handle-invited` store the first alias there instead of in `name`, and make the invited branch of `neoment-room-display-name` use name ≠ id → alias → members → `Empty room` (design D3). Verify with new tests in `test/neoment-events-test.el` covering both orders (name then alias, alias then name → `Dev`). Update the alias part of `neoment-events-invited-empty-name` and `neoment-sync-invited-room-by-alias` (`test/neoment-sync-test.el`) to assert on `neoment-room-display-name` (`#alt:s` / `#dev:example.org`) instead of `neoment-invited-room-name`.

## 3. Cache format and legacy migration

- [ ] 3.1 In `neoment-storage.el` `neoment-storage--room-to-json`, write `explicit_name` (the name when it is not the id, otherwise `:null`) next to the existing `name`. In `neoment-storage--room-from-json`, read `explicit_name` when the key is present (null → id). Without it, use the legacy `name`, unless that name is a member of the stored `aliases`, in which case use the id (design D5). Verify with tests next to `neoment-storage-cache-compact-room` in `test/neoment-events-test.el`: an unnamed room with alias `#old:s` round-trips with `explicit_name` null and then follows an alias change to `#new:s`; a legacy JSON with `name` `#old:s` / aliases `["#old:s"]` loads unnamed; a legacy JSON with `name` `Dev` / aliases `["#dev:s"]` loads as `Dev`. The existing round-trip test must still assert `dev`.
- [ ] 3.2 Make storage save and load the invited room's `alias` (`neoment-storage--invited-room-to-json` / `-from-json`, missing key → nil). Verify with a round-trip test: an invite with only an alias keeps its display name after save and load.

## 4. Refresh-state messages

- [ ] 4.1 In `neoment-rooms.el` `neoment-rooms-refresh-room-state`, format `Refreshing state for <n>...`, `State updated for <n>` and `No new state for <n>` with `neoment-room-display-name` instead of `neoment-room-name` (design D4). Verify that the existing assertions in `test/neoment-rooms-test.el` (around lines 529–537, room named `dev`) still pass, and add one case where an alias-only room shows `Refreshing state for #dev:s...`.

## 5. Integration checks

- [ ] 5.1 Run `make compile` (byte-compile with warnings as errors), `make lint` and `make test`, and confirm all three pass.
- [ ] 5.2 Run `openspec validate fix-room-alias-name --strict` and confirm the change is valid.

## Workflow follow-up

- Reference issue #22 in the PR (`Fixes #22`).
- Archive the change after review, which syncs the matrix-events, matrix-sync and session-management deltas.
