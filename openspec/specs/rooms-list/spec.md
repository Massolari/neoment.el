# rooms-list Specification

## Purpose

Provides the main navigation surface. A side window lists every room in sections with icons, relative times, unread badges and last-message previews, and offers per-room actions. Room pickers give quick access from anywhere.

## Requirements

### Requirement: Rooms list window
The room list SHALL live in a buffer named ` *neoment-rooms*` (with a leading space), which hides it from normal buffer switching. It SHALL be shown in a dedicated, fixed-width left side window, `min(50, floor(20% of frame width))` columns wide, with the current line highlighted and no line numbers. `neoment-toggle-rooms-list` SHALL close the window if it exists and open it otherwise.

#### Scenario: Toggle
- **WHEN** the room list window is visible and the user runs `neoment-toggle-rooms-list`
- **THEN** the window closes

#### Scenario: Width on a 300-column frame
- **WHEN** the frame is 300 columns wide
- **THEN** the side window is 50 columns wide

#### Scenario: Hidden buffer name
- **WHEN** the room list is open
- **THEN** its buffer is named ` *neoment-rooms*` and does not appear among the candidates of `switch-to-buffer`

### Requirement: Opening rooms from the list
Opening a room or info buffer from the list SHALL create a window to the right with the remaining width when the list is the only window. Otherwise it SHALL reuse the window to the right of the list.

#### Scenario: List is the only window
- **WHEN** the user opens a room while only the list window exists
- **THEN** a new window to the right shows the room

### Requirement: Empty states
Before any sync the buffer SHALL show only `No sync yet`. During the first sync it SHALL show `Syncing...`.

#### Scenario: First sync in progress
- **WHEN** the first sync has not completed
- **THEN** the buffer shows `Syncing...`

### Requirement: Header lines
Line 1 SHALL be `"─" * floor(n/2) + " Neoment " + "─" * ceil(n/2)` with `n = width - 9`. Line 2 SHALL be a bubble `<display name> │ <icon> <presence>`, then two spaces and the sync status. Line 3 SHALL be empty.
- Presence: online `●`, unavailable `◐`, otherwise `○ offline`.
- Sync status: never synced → `◇ connecting` / `◇ offline`; under 60 s → `● synced`; under 1 h → `● <m>m ago`; otherwise `○ HH:MM`.

#### Scenario: Recently synced
- **WHEN** the last sync was 10 s ago and presence is online
- **THEN** line 2 contains `● online` and `● synced`, with the synced icon in the success face

#### Scenario: Title width
- **WHEN** the window is 30 columns wide
- **THEN** line 1 is 10 `─`, ` Neoment `, 11 `─`

### Requirement: Sections and classification
Each room SHALL appear in exactly one section, chosen by this priority:
1. open in a buffer → Buffers
2. favourite → Favorites
3. DM → People
4. low priority → Low priority
5. a space that is not a child of another space → Spaces
6. otherwise → Rooms

Invited rooms go to Invited. Favorites, People, Rooms and Low priority are always shown. Invited, Buffers and Spaces only appear when not empty. Headers read `<arrow> <icon>  <Name> (<n>)`, and an empty line separates sections.

#### Scenario: Favourite DM open in buffer
- **WHEN** a favourite DM room is open in a buffer
- **THEN** it appears only under Buffers

#### Scenario: No invites
- **WHEN** there are no invited rooms
- **THEN** no Invited section is rendered

### Requirement: Ordering
Spaces SHALL be sorted by name (case-insensitive, ties by id). The other sections SHALL order rooms in three groups: first rooms with unread highlights or notifications, then other unread rooms, then read rooms. Within each group, the most recent activity SHALL come first. Highlights and notifications SHALL share the first group and SHALL NOT be ranked against each other.

#### Scenario: Unread before recent
- **WHEN** room A is read with activity 1 min ago and room B is unread with activity 1 h ago
- **THEN** B is listed before A

#### Scenario: Notifications before unread
- **WHEN** room A is unread without counts and has activity 1 min ago, and room B has 1 unread notification and activity 1 h ago
- **THEN** B is listed before A

#### Scenario: Highlights before unread
- **WHEN** room A is unread without counts and has activity 1 min ago, and room B has 1 unread highlight and activity 1 h ago
- **THEN** B is listed before A

#### Scenario: Counts rank first even when read
- **WHEN** room A is unread without counts and has activity 1 min ago, and room B has 1 unread notification, activity 1 h ago, and its read marker on its last event
- **THEN** B is listed before A

#### Scenario: Highlights and notifications ordered by activity
- **WHEN** room A has 1 unread highlight and activity 1 h ago, and room B has 1 unread notification and activity 1 min ago
- **THEN** B is listed before A

#### Scenario: Full ordering within a section
- **WHEN** a section holds a read room with activity 1 min ago, an unread room with activity 5 min ago, and a room with notifications with activity 1 h ago
- **THEN** they are listed as: the room with notifications, the unread room, the read room

### Requirement: Room line format
A room line SHALL be: 2 spaces of indent per level, the icon (space/DM/room) and 2 spaces, then the name (`Space/Room` with `space_room` format outside Spaces), then ` <relative time>`, ` <badge>`, and ` <space name>` with `room_space` format outside Spaces. Relative time is `now`, `<m>m`, `<h>h`, `<d>d`, or `dd/mm` from 7 days on. The badge needs last activity: highlights → bell (error face), notifications → dot-circle (warning face), unread → `•` (info face).

#### Scenario: Highlighted room
- **WHEN** a room has 1 highlight and activity 5 minutes ago
- **THEN** its line ends with ` 5m 󰵛`, the bell in the error face

#### Scenario: Old activity
- **WHEN** a room's last activity is 10 days ago on 13 November
- **THEN** its time shows `13/11`

### Requirement: Room line faces
Rooms in buffers SHALL use `neoment-buffer-room`, or `neoment-buffer-room-unread` when they have counts. Other rooms with counts SHALL use `neoment-room-unread`. Icons SHALL use `neoment-room-icon-buffer`, `neoment-room-icon-unread` or `neoment-room-icon`.

#### Scenario: Unread room icon
- **WHEN** a room not in a buffer is unread
- **THEN** its icon has the face `neoment-room-icon-unread`

### Requirement: Last message preview
Except for spaces, each room SHALL have a preview line according to `neoment-rooms-display-last-message`:
- `message`: `<indent>  │ <content>`
- `sender_message`: two lines, sender then content
- `sender_message_inline`: `<sender>: <content>`
- `no`: no preview

Content is at most 40 columns (39 + `…`), with newlines turned into spaces; empty text with an attachment shows `<type icon> <filename>`. The sender is at most 15 columns (14 + `…`). Preview lines MUST NOT select a room.

#### Scenario: Long message
- **WHEN** the last message is 60 characters long
- **THEN** the preview shows its first 39 characters followed by `…`

#### Scenario: Cursor on preview
- **WHEN** the user presses RET on a preview line
- **THEN** `No room found on this line. Position the cursor directly over the room name.` is shown

### Requirement: Spaces tree
The Spaces section SHALL show each space as `<indent><arrow> <name>`, folded by default. Its children are the rooms the user belongs to, nested recursively one indent level deeper. Fold state is keyed by space id.

#### Scenario: Expand space
- **WHEN** the user presses TAB on a folded space line
- **THEN** its joined child rooms and sub-spaces appear indented below it

### Requirement: Persistent folding
TAB SHALL toggle the fold of the section or space on the current line. On any other line it SHALL show `No section found on this line. Position the cursor over a section title.`. Fold state SHALL be saved to `ui_state.json` and restored in later sessions.

#### Scenario: Fold survives restart
- **WHEN** the user folds People and restarts Emacs
- **THEN** People is still folded

### Requirement: Rooms list actions
In `neoment-rooms-mode`:
- RET opens the room or space, or answers an invite
- `q` closes the window
- `a`/`l` toggle the `m.favourite`/`m.lowpriority` tags
- `d` toggles `is_direct` locally only
- `f`/`F` open the pickers
- `i` opens room info
- `n`/`p` move to the next/previous room, space or section line, skipping preview lines
- `N` opens the room notification settings
- `M-n` opens the global notification settings
- `r` toggles read
- `s` changes presence
- `u` refreshes room state

Without a room on the line, actions SHALL show `No room found on this line. Position the cursor directly over the room name.`.

#### Scenario: Favourite an invite
- **WHEN** the user presses `a` on an invited room
- **THEN** `You cannot add an invited room to favorites.` is shown

#### Scenario: Toggle direct locally
- **WHEN** the user presses `d` on a non-DM room
- **THEN** `<name> marked as direct` is shown and no request is sent

#### Scenario: Room settings for invite
- **WHEN** the user presses `N` on an invited room
- **THEN** `Notification settings are available after joining the room.` is shown

### Requirement: Room list navigation
`n`/`p` SHALL move to the start of the next/previous line that has a room, a space or a section header, skipping preview and blank lines. With nothing further in that direction they SHALL show `No more rooms in this direction`.

#### Scenario: Skip preview line
- **WHEN** the cursor is on a room that has a preview line and the user presses `n`
- **THEN** the cursor lands on the next room's line, not on the preview

#### Scenario: End of list
- **WHEN** the cursor is on the last room and the user presses `n`
- **THEN** `No more rooms in this direction` is shown

### Requirement: Toggle read state
`r` SHALL mark an unread room (highlights, notifications, or the unread rule) as read with a private `m.read.private` receipt on the last activity event, and show `Room '<n>' marked as read`. When the receipt succeeds, the room's highlight and notification counts SHALL be set to 0 locally, so the room leaves the notifications group before the next sync. Otherwise it SHALL send `m.marked_unread {unread:true}` and show `Room '<n>' marked as unread`.

#### Scenario: Mark read room as unread
- **WHEN** the user presses `r` on a read room
- **THEN** an `m.marked_unread` event with `unread: true` is sent

#### Scenario: Mark as read clears counts
- **WHEN** the user presses `r` on a room with 1 unread notification and the receipt succeeds
- **THEN** the room has no highlights or notifications and is no longer listed in the notifications group

### Requirement: Change presence
`s` SHALL prompt `Change status (current: <x>):` with `● online`, `◐ unavailable` and `○ offline`. It SHALL store the choice as the desired presence and show `Status will change to '<x>' on next sync`.

#### Scenario: Go unavailable
- **WHEN** the user picks unavailable
- **THEN** the next sync uses `set_presence=unavailable`

### Requirement: Refresh room state
`u` SHALL show `Refreshing state for <n>...` and `GET /rooms/<r>/state`, applying only tombstone, name, topic, canonical_alias and space.child. It then shows `State updated for <n>` or `No new state for <n>`.

#### Scenario: No change
- **WHEN** the fetched state matches local state
- **THEN** `No new state for <n>` is shown

### Requirement: Room pickers
`neoment-pick-room` (prompt `Select a room:`) and `neoment-pick-open-room` (prompt `Select an open room:`, or `No open rooms` when there are none) SHALL show spaces as `󰴖  <name>` and rooms as `<icon>  <Space/Name> [<time>] <badge>`, with time and badge only when there is activity. The picker functions SHALL be customisable and default to `completing-read`.

#### Scenario: No open rooms
- **WHEN** no room buffers are open and the user runs `neoment-pick-open-room`
- **THEN** `No open rooms` is shown
