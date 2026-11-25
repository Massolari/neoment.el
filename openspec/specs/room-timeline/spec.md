# room-timeline Specification

## Purpose

Shows a room or thread conversation in a read-only Emacs buffer with a fixed 31-column gutter (time and sender), date separators, rich replies, reactions, unread marker, typing and tombstone notices. It loads history, marks the room read, and re-renders without moving the cursor.

## Requirements

### Requirement: Room buffer identity
A room buffer SHALL be named `neoment://room/<room_id>/<Space/Name>`. If it already exists, opening it again shows and re-renders it. The initial content SHALL be 28 spaces + ` │ ` + `Loading...`.

#### Scenario: Reopen existing room
- **WHEN** the user opens a room whose buffer already exists
- **THEN** that buffer is displayed and no second buffer is created

### Requirement: Room buffer display
The room buffer SHALL use visual line wrapping, no line numbers and a highlighted current line. Wrapped continuation lines SHALL start with 29 spaces + `│ ` (separator face). The header line SHALL be `<room name>`, plus ` - <topic>` when there is a topic. Thread buffers SHALL show `🧵 Thread in <name>`.

#### Scenario: Header with topic
- **WHEN** the room "dev" has topic "Daily chat"
- **THEN** the header line shows `dev - Daily chat`

### Requirement: Opening loads data
Opening a room buffer SHALL start tracking the room, load the first history page, fetch `GET /rooms/<r>/joined_members` to fill members and display names, and re-render when that data arrives. Killing a room buffer (not a thread buffer) SHALL stop tracking and release the room's data.

#### Scenario: Kill room buffer
- **WHEN** the user kills a room buffer
- **THEN** the room is untracked and keeps only its last message

### Requirement: Message header line
The first line of each non-state message SHALL be `HH:MM:SS`, a space, the sender name right-aligned and truncated to 19 columns (bold, with a per-room colour from a cycle of 20 faces assigned in order of first appearance), then ` │ ` in the separator face. That is 31 columns in total. Later lines SHALL start with 28 spaces + ` │ `. Lines that are only whitespace SHALL become empty.

#### Scenario: Short name alignment
- **WHEN** Alice sends "hi" at 09:12:44
- **THEN** the line reads `09:12:44               Alice │ hi`

#### Scenario: Long name truncation
- **WHEN** the sender name is 25 characters long
- **THEN** only its first 19 characters appear in the gutter

### Requirement: Sender name display width
The 19-column sender name limit in the message header line SHALL be measured as displayed width, counting composed glyphs (emoji with variation selectors, ZWJ sequences, combining marks) as they display. Truncation SHALL keep only whole glyphs. Rendering a message header SHALL NOT fail for any sender name, and the header SHALL stay 31 columns wide.

#### Scenario: Name of emoji with variation selectors
- **WHEN** the sender name is twenty `❤️` (heart + U+FE0F, each displayed 2 columns wide)
- **THEN** the room renders without error
- **AND** the gutter shows whole `❤️` glyphs taking at most 19 columns, right-aligned with leading spaces so the header is 31 columns

#### Scenario: Wide characters that do not fill the column exactly
- **WHEN** the sender name is twenty fullwidth characters, each 2 columns wide
- **THEN** the gutter shows nine of them (18 columns) preceded by one space

#### Scenario: Name of ZWJ emoji sequences
- **WHEN** the sender name is a series of ZWJ family emoji (e.g. `👨‍👩‍👧‍👦`)
- **THEN** each family shows whole or not at all, and the header is 31 columns wide

### Requirement: Decorations excluded from copy
Time, sender, gutter, separators, icons and bubbles SHALL be marked as decoration. Copying text from the room buffer MUST leave decoration out, so only message content is copied. Every line SHALL map to its owning message.

#### Scenario: Copy a message line
- **WHEN** the user copies the line `09:12:44               Alice │ hi`
- **THEN** the kill ring receives `hi`

### Requirement: Thread filtering
The room buffer SHALL hide messages that have `thread_root_id`. A thread buffer SHALL show the root and the messages in that thread. In the room buffer, a root with `thread_replies_count > 0` SHALL show a bubble line `↳ <n> reply` or `↳ <n> replies`.

#### Scenario: Root with replies
- **WHEN** a root has 3 thread replies
- **THEN** the room buffer shows the root followed by a `↳ 3 replies` bubble and none of the replies

### Requirement: Date separators
When the date (`%A %B %d, %Y`) changes, a separator SHALL appear: 28 spaces + ` ├` + 60 columns with ` <date> ` centred between `─`. For the first message it goes on line 1, which is otherwise empty. For later messages it goes on its own line above the message header.

#### Scenario: Day change
- **WHEN** consecutive messages are on 22 and 23 November 2026
- **THEN** a separator containing ` Monday November 23, 2026 ` appears before the second message

### Requirement: Message body rendering
The body SHALL be `formatted_content` converted to markdown, or else `content`, with NUL characters removed. A reply SHALL be prefixed by `┃ <replied sender>:` and each non-empty replied line as `┃ <line>`, in the comment face. Redacted and state messages SHALL render the whole header line in the comment face. State messages have no time or name. Edited messages SHALL end their last line with ` (edited)` in the comment face.

#### Scenario: Edited reply
- **WHEN** Bob edits a reply to Alice
- **THEN** the body shows `┃ Alice:` and the quoted lines, then Bob's text ending in ` (edited)`

#### Scenario: Membership line
- **WHEN** Carol joins
- **THEN** a line of 28 spaces + ` │ Membership: Carol joined the room` appears in the comment face

### Requirement: Attachment bubbles
An attachment SHALL render as a bordered bubble on the first body line, one of: `󰋩  Image[: f]`, `󰈙  File[: f] │ <size>`, `  Audio[: f] │ <dur> │ <size>`, `  Video[: f] │ <dur> │ <size>`, `󰍎  Location`. A caption (body) different from the filename goes on the next line. Size is `%.2f` + B/KB/MB/GB/TB (base 1024) or `?.? B`. Duration is `mm:ss`/`hh:mm:ss` or `--:--`.

#### Scenario: File size
- **WHEN** a file attachment is 1536 bytes named `a.pdf`
- **THEN** the bubble reads `󰈙  File: a.pdf │ 1.50 KB`

#### Scenario: Unknown duration
- **WHEN** an audio attachment has no duration
- **THEN** the bubble shows `--:--`

#### Scenario: Filename taken from body
- **WHEN** an image has no `filename` but its body is `cat.png` with mimetype `image/png`
- **THEN** the bubble reads `󰋩  Image: cat.png` and no caption line is added

#### Scenario: No filename at all
- **WHEN** an image has no filename and its body is `look at this`
- **THEN** the bubble reads `󰋩  Image` and `look at this` appears on the next line

### Requirement: Reaction line
After the body, a line SHALL show one bubble per reaction key, `<key>` or `<key> <n>` when n > 1, with no spaces between bubbles. Keys the user reacted with SHALL use the active bubble faces.

#### Scenario: Own reaction highlighted
- **WHEN** the user and one other person reacted 👍
- **THEN** the bubble reads `👍 2` in the active faces

### Requirement: Mentions and emoticons
Markdown links to `https://matrix.to/#/@user:server` SHALL use `neoment-mention`, or `neoment-mention-user` when they point at the current user. `[img: <title>](mxc://...)` SHALL use `neoment-emoticon`. Only `mxc://` URLs count as emoticons.

#### Scenario: Self mention
- **WHEN** a message mentions the current user
- **THEN** that link text has the face `neoment-mention-user`

### Requirement: Unread marker
After the message whose id equals `fully_read`, if any visible non-redacted, non-state messages follow it, the buffer SHALL show 28 spaces + ` ├` + a 60-column rule containing `  New messages  ` framed by the down-arrow-circle icon, in the separator face.

#### Scenario: Only state after marker
- **WHEN** only membership messages follow the fully-read message
- **THEN** no "New messages" marker is shown

### Requirement: Tombstone and typing
A tombstoned room SHALL end with an empty line and then, in the tombstone face, `<body>`, `New room: <replacement>` and `Use M-x neoment-join <replacement> to join the new room.`. When users are typing, a final line of 28 spaces + ` │ Typing: A, B` in the comment face SHALL appear.

#### Scenario: Typing users
- **WHEN** Alice and Dave are typing
- **THEN** the last line reads `Typing: Alice, Dave` after the gutter

### Requirement: Stable re-render
Re-rendering MUST keep the cursor on the same message and offset, and keep the window start. New messages MUST NOT make the cursor jump. On the first page load (no previous `prev_batch`) with the buffer visible, the cursor SHALL move to the last line. `revert-buffer` (`g`) SHALL re-render.

#### Scenario: Message arrives while reading
- **WHEN** the cursor is on an older message and a new message arrives
- **THEN** the cursor stays on the same message and column

### Requirement: History pagination
Loading history SHALL `GET /rooms/<r>/messages?limit=20&dir=b&from=<prev_batch token or sync token>`. A present `end` sets `prev_batch = {token: end}`. A missing `end` sets `End`. An empty chunk with `end` SHALL fetch the next page automatically. Messages: `Loading more messages...`, then `Messages loaded` or `Error loading more messages: <e>`. When at `End`: `No more messages to load`.

#### Scenario: Start of history
- **WHEN** the user loads more and `prev_batch` is `End`
- **THEN** `No more messages to load` is shown and no request is sent

### Requirement: Automatic read marking
When the buffer is entered, and after each update while it is visible, the client SHALL do two things. If `unread` is set, it sends `m.marked_unread {unread:false}` and refreshes the list. If the room is unread with last activity, it `POST /rooms/<r>/read_markers` with `m.read` and `m.fully_read` = last activity id, updating local state (a local receipt) before the response arrives and re-rendering.

#### Scenario: Enter unread room
- **WHEN** the user switches to the buffer of an unread room
- **THEN** read markers are sent and the room list badge disappears immediately

### Requirement: Hover popups
After about 0.5 s idle on a reaction, the client SHALL show a popup near the cursor. It has the reaction label (emoji name from the emoji table, or the key) in bold, an empty line, and the display names of the reactors. For `mxc://` keys in GUI frames, it also shows the image (8 lines). On an `mxc://` emoticon in a GUI frame, it SHALL show the bold title and the image. Moving the cursor SHALL close the popup. Without popup support the text goes to the echo area.

#### Scenario: Terminal frame
- **WHEN** the cursor rests on a 👍 reaction in `emacs -nw`
- **THEN** the echo area shows the emoji label and the reactor names

### Requirement: Link URL at point
After about 0.5 s idle with the cursor on a link's visible text in a room or thread buffer, the echo area SHALL show the link's URL, in GUI and terminal frames. Moving the cursor and idling again on another link SHALL show that link's URL. A spoiler SHALL show nothing. An `mxc://` emoticon SHALL keep its hover popup instead. The mouse tooltip on link text SHALL still show the URL.

#### Scenario: Cursor on a link
- **WHEN** the body is `see [docs](https://example.org)` and the cursor rests on `docs` for 0.5 s, in a GUI or a terminal frame
- **THEN** the echo area shows `https://example.org` and no popup frame is shown

#### Scenario: Cursor on a mention
- **WHEN** the cursor rests on the mention `Alice` of `[Alice](https://matrix.to/#/@alice:s)`
- **THEN** the echo area shows `https://matrix.to/#/@alice:s`

#### Scenario: Cursor on a spoiler
- **WHEN** the cursor rests on `Spoiler` of `[Spoiler](<the end>)`
- **THEN** nothing is shown and `the end` does not appear in the echo area

#### Scenario: Cursor on an emoticon
- **WHEN** the cursor rests on an `mxc://` emoticon link in a GUI frame
- **THEN** the emoticon popup is shown as before, not the `mxc://` URL

#### Scenario: Cursor off a link
- **WHEN** the cursor rests on plain body text
- **THEN** no URL is shown

#### Scenario: Mouse hover keeps the tooltip
- **WHEN** the mouse hovers over the link text `docs`
- **THEN** the tooltip (or the echo area, with `tooltip-mode` off) shows `https://example.org`
