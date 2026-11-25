# Tasks

Notes: this change has no `design.md`. The approach is a three-level rank inside `neoment-rooms--activity<` (`neoment-rooms.el:113`):
- 0: the room has counts, using the existing `neoment-rooms--has-counts`. This is the same test that decides the badge and the unread line face, so the order matches what the user sees.
- 1: `neoment-room-unread-p`.
- 2: read.

Compare ranks first and timestamps second. A room with counts is ranked 0 even if `neoment-room-unread-p` is nil.

## 1. Three-level activity ordering

- [ ] 1.1 Add a small helper in `neoment-rooms.el` (for example `neoment-rooms--attention-rank`) that returns 0/1/2 as described above. Rewrite `neoment-rooms--activity<` to compare the ranks and then the last-activity timestamps (newest first). Update its docstring. Verify that `make compile` shows no warnings.
- [ ] 1.2 In `test/neoment-rooms-test.el`, next to `neoment-rooms-unread-before-recent`, add ERT tests for each new scenario in the delta spec:
  - a room with notifications before a newer unread room
  - a room with highlights before a newer unread room
  - a room with highlights and a room with notifications ordered only by activity
  - the full order in one section: notifications → unread → read

  Use the `:notifications` and `:highlights` options of `neoment-rooms-test-room` with `neoment-rooms--classify`. Verify that `make test` passes, including the existing `neoment-rooms-unread-before-recent`.
- [ ] 1.3 Add a test that `neoment-pick-room` (which sorts with the same comparator) lists a room with notifications first, for example by stubbing `neoment-rooms-pick` and capturing its id list. Verify with `make test`.

## 2. Integration checks

- [ ] 2.1 Run `make compile lint test` and confirm that all three pass with no byte-compile warnings.

## Workflow follow-up

- Archive the change after review. This syncs the modified **Ordering** requirement into `openspec/specs/rooms-list/spec.md`.
