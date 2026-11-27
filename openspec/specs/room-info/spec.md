# room-info Specification

## Purpose

Shows a room's details (type, topic, space, status flags, links, members and avatar) in one buffer. From there the user can toggle the favourite, low-priority and direct flags, and open or zoom the avatar.

## Requirements

### Requirement: Room info buffer
The buffer SHALL be named `*neoment-room-info: <Space/Name>*`, without the room ID. When opened from a room it shows in a window to the right, 50 columns wide.

#### Scenario: Open from room
- **WHEN** the user presses `i` in a room buffer
- **THEN** the info buffer appears in a 50-column window to the right

#### Scenario: Info buffer name
- **WHEN** the user opens the information of room `!r:s`, displayed as `dev`
- **THEN** the buffer is named `*neoment-room-info: dev*`

### Requirement: Room info layout
The buffer SHALL show, in this order: a `─`-framed centred title; the avatar (16×8, GUI) or `No image`, with an open hint; `Room Type: Room|Space|Direct Message`; `Topic:` (if any); `Space: <name>` (if any); `Status:` toggles; `── Links ──` with `Room ID:` and `Aliases:`; and the members header.

#### Scenario: Favourite room
- **WHEN** the room is a favourite
- **THEN** the Favorite status renders as an active bubble with its `[a] toggle` hint, and the inactive statuses render in the comment face

#### Scenario: Invited room status
- **WHEN** the room is an invite
- **THEN** the Direct Message status line is omitted

#### Scenario: Aliases
- **WHEN** the room has alias `#dev:s`
- **THEN** the Links section lists `  - #dev:s` under `Aliases:`

### Requirement: Members list
The members header SHALL read `── Members (<n>) ── [Tab to expand]` when collapsed and `── Members (<n>) ──` when expanded. Expanded, it lists `  - <Name> (<id>)`, with the id in the comment face, or `  - <id>` when there is no display name. Members are sorted case-insensitively by display name. TAB SHALL toggle the list.

#### Scenario: Expand members
- **WHEN** the user presses TAB on a collapsed members header
- **THEN** sorted member lines appear

### Requirement: Status toggles
`a`, `l` and `d` SHALL toggle favourite, low priority and direct, re-rendering the buffer. On invited rooms they show `Cannot modify status for invited rooms`.

#### Scenario: Toggle low priority
- **WHEN** the user presses `l` on a normal room
- **THEN** the `m.lowpriority` tag is added and `<name> added to low priority` is shown

### Requirement: Avatar actions
`o` SHALL open the avatar with the attachment handler (origin `avatar`), or show `No avatar image to open`. `z` SHALL toggle the avatar between 16×8 and window size, or show `No avatar image to zoom`. Only `mxc://` avatars are downloaded. `f`/`F` open the pickers.

#### Scenario: No avatar
- **WHEN** the room has no avatar and the user presses `o`
- **THEN** `No avatar image to open` is shown

### Requirement: Close room info
`q` in the room info buffer SHALL kill the buffer and close the window it is in, if opening the info buffer created that window. It SHALL then select the window that was selected before. If the info buffer was shown in a window that already existed, `q` SHALL kill the buffer, leave the window open, and show the buffer that window showed before.

#### Scenario: Close side window opened from room
- **WHEN** the user presses `i` in a room buffer and then `q` in the info window
- **THEN** the info buffer is killed, the 50-column window on the right is deleted, and the room window is selected and has its previous width

#### Scenario: Close info shown in an existing window
- **WHEN** the info buffer was opened in the selected window in place of the buffer shown there, and the user presses `q`
- **THEN** the info buffer is killed, the window stays open, and it shows the buffer it showed before

#### Scenario: Only window
- **WHEN** the info buffer is the only window in the frame and the user presses `q`
- **THEN** the info buffer is killed, no error occurs, and the window shows another buffer

### Requirement: Tag requests
Toggling a tag SHALL `PUT /user/<u>/rooms/<r>/tags/<tag>` with `{order:0}` or `DELETE` the same path. It shows `<name> added to favorites`/`removed from favorites` (or `low priority`). Errors show `Error adding <name> to favorites: <e>`.

#### Scenario: Tag error
- **WHEN** the tag PUT fails
- **THEN** `Error adding <name> to favorites: <e>` is shown
