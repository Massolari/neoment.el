# Spec Delta

## Purpose

Shows a room's details (type, topic, space, status flags, links, members and avatar) in one buffer. From there the user can toggle the favourite, low-priority and direct flags, and open or zoom the avatar.

## ADDED Requirements

### Requirement: Room info buffer
The buffer SHALL be named `neoment://room/info/<id>/<Space/Name>`. When opened from a room it shows in a window to the right, 50 columns wide.

#### Scenario: Open from room
- **WHEN** the user presses `i` in a room buffer
- **THEN** the info buffer appears in a 50-column window to the right

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
`o` SHALL open the avatar with the attachment handler (origin `avatar`), or show `No avatar image to open`. `z` SHALL toggle the avatar between 16×8 and window size, or show `No avatar image to zoom`. Only `mxc://` avatars are downloaded. `q` kills the buffer, and `f`/`F` open the pickers.

#### Scenario: No avatar
- **WHEN** the room has no avatar and the user presses `o`
- **THEN** `No avatar image to open` is shown

### Requirement: Tag requests
Toggling a tag SHALL `PUT /user/<u>/rooms/<r>/tags/<tag>` with `{order:0}` or `DELETE` the same path. It shows `<name> added to favorites`/`removed from favorites` (or `low priority`). Errors show `Error adding <name> to favorites: <e>`.

#### Scenario: Tag error
- **WHEN** the tag PUT fails
- **THEN** `Error adding <name> to favorites: <e>` is shown
