# Design

## Context

Each buffer kind gets its name from one function: `neoment-room-buffer-name`, `neoment-room-thread-buffer-name`, `neoment-room-info-buffer-name`, `neoment-space-buffer-name`, `neoment-compose-buffer-name`, plus the constant `neoment-rooms-buffer-name`. Nothing finds a buffer by its name. Rooms and threads are found with `neoment-room--find-buffer` through `neoment--room-id` and `neoment--thread-root-id`. Space and info buffers are found by major mode plus a buffer-local ID. The rooms list is found through the constant itself. Buffers are created with `generate-new-buffer`, which already adds `<N>` when a name is taken.

## Goals / Non-Goals

**Goals:**
- Follow the Emacs convention, and the package's own existing names (`*neoment-player*`, `*neoment-image: …*`), with one predictable pattern.
- Keep each buffer-kind's name in one place.

**Non-Goals:**
- Renaming live buffers when a room or space display name changes after the buffer was created (current behavior; unchanged).
- Adding `uniquify` integration or a user option for the name format.

## Decisions

- **Format `*neoment-<kind>: <label>*`.** It matches `*neoment-image: <file>*`. The `neoment-` prefix groups the package's buffers when completing on `*neoment`, and the kind lets the user tell a room from its info or compose buffer. Alternatives considered:
  - `*<Space/Name>*`: shorter, but it can't be told apart from other packages' buffers or from the room's info buffer.
  - `*Neoment Room: …*`: title case doesn't match the package's existing lowercase names.
- **Drop Matrix IDs from names.** IDs like `!abc:server` aren't useful to read, and names don't have to be unique for lookup. If two rooms share a display name, `generate-new-buffer` gives `<2>`. Keeping the ID would make every name long just to cover that rare case.
- **The thread name gets the room instead of the root ID.** `*neoment-thread: <author> in <room>*` mirrors the compose wording ("Sending to thread in <room>"). That means `neoment-room-thread-buffer-name` must take `room-id` (it changes from `(root-id author)` to `(room-id author)`). Its only caller, `neoment-room-open-thread-buffer`, already has `room-id`. The room part uses `neoment-room-display-name` (no space prefix) to keep thread names short.
- **The rooms list keeps the leading space.** ` *neoment-rooms*` stays hidden from `switch-to-buffer`. Only the `defconst` value changes, and every user of it reads the constant.

## Risks / Trade-offs

- [Users' `display-buffer-alist` or other config that matches `neoment://`] → Mentioned as BREAKING in the proposal; the new prefix `*neoment-` can be matched just as easily.
- [Two threads by the same author in the same room get the same name] → Told apart by `<2>`; lookup is unaffected because it uses `neoment--thread-root-id`.
- [Display names that contain `*`] → Only cosmetic; Emacs allows any characters in buffer names.

## Migration Plan

No data migration. Buffers created before an upgrade keep their old names until they are killed. Rolling back means restoring the old format strings.
