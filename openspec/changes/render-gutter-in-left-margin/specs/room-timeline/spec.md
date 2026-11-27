# Spec Delta

## MODIFIED Requirements

### Requirement: Room buffer identity
A room buffer SHALL be named `*neoment-room: <Space/Name>*`. The name SHALL NOT contain the room ID, except when the room's display name is not known yet (for example, a room opened right after joining, before the next sync); then `neoment-room-display-name` falls back to the room ID. When another buffer already has that name, Emacs' standard `<N>` suffix tells them apart. If the room's buffer already exists, opening the room again shows and re-renders it. The initial content SHALL be `Loading...`.

#### Scenario: Reopen existing room
- **WHEN** the user opens a room whose buffer already exists
- **THEN** that buffer is displayed and no second buffer is created

#### Scenario: Room buffer name
- **WHEN** the user opens room `!r:s`, whose display name is `dev`, which is in no space
- **THEN** the buffer is named `*neoment-room: dev*`

#### Scenario: Two rooms with the same display name
- **WHEN** the user opens two different rooms that are both displayed as `dev`
- **THEN** the buffers are named `*neoment-room: dev*` and `*neoment-room: dev*<2>`, and each one shows its own room

#### Scenario: Initial content
- **WHEN** a room buffer is created before its first render
- **THEN** its text is exactly `Loading...`, starting at column 0 of the text area

### Requirement: Room buffer display
The room buffer SHALL use visual line wrapping, no line numbers and a highlighted current line. Room and thread buffers SHALL have a 29-column left margin in every window that shows them. Wrapped continuation lines SHALL start at column 0 of the text area, with no prefix. The header line SHALL be `<room name>`, plus ` - <topic>` when there is a topic. Thread buffers SHALL show `🧵 Thread in <name>`.

#### Scenario: Header with topic
- **WHEN** the room "dev" has topic "Daily chat"
- **THEN** the header line shows `dev - Daily chat`

#### Scenario: Left margin
- **WHEN** a room buffer is shown in a window
- **THEN** that window's left margin is 29 columns wide

#### Scenario: Soft-wrapped line
- **WHEN** a message line is longer than the window's text area
- **THEN** its wrapped part starts at column 0 of the text area and the margin beside it is empty

### Requirement: Message header line
For the first line of each non-state message, the left margin SHALL show `HH:MM:SS`, a space, the sender name right-aligned and truncated to 19 columns (bold, with a per-room colour from a cycle of 20 faces assigned in order of first appearance), and a space. That is 29 columns in total. Time and sender SHALL NOT be buffer text. Content SHALL start at column 0 of the text area. Later lines SHALL have an empty margin. Lines that are only whitespace SHALL become empty.

#### Scenario: Short name alignment
- **WHEN** Alice sends "hi" at 09:12:44
- **THEN** the margin shows `09:12:44               Alice ` and the text area of that line shows `hi`

#### Scenario: Long name truncation
- **WHEN** the sender name is 25 characters long
- **THEN** only its first 19 characters appear in the margin

#### Scenario: Multi-line message
- **WHEN** Alice sends a message with two lines
- **THEN** the second line shows its text at column 0 of the text area and its margin is empty

### Requirement: Sender name display width
The 19-column sender name limit in the margin of the message header line SHALL be measured as displayed width, counting composed glyphs (emoji with variation selectors, ZWJ sequences, combining marks) as they display. Truncation SHALL keep only whole glyphs. Rendering a message header SHALL NOT fail for any sender name, and the margin text SHALL stay 29 columns wide.

#### Scenario: Name of emoji with variation selectors
- **WHEN** the sender name is twenty `❤️` (heart + U+FE0F, each displayed 2 columns wide)
- **THEN** the room renders without error
- **AND** the margin shows whole `❤️` glyphs taking at most 19 columns, right-aligned with leading spaces so the margin text is 29 columns

#### Scenario: Wide characters that do not fill the column exactly
- **WHEN** the sender name is twenty fullwidth characters, each 2 columns wide
- **THEN** the margin shows nine of them (18 columns) preceded by one space

#### Scenario: Name of ZWJ emoji sequences
- **WHEN** the sender name is a series of ZWJ family emoji (e.g. `👨‍👩‍👧‍👦`)
- **THEN** each family shows whole or not at all, and the margin text is 29 columns wide

### Requirement: Decorations excluded from copy
Time, sender, separators, icons and bubbles SHALL be marked as decoration or be shown outside the buffer text. Copying text from the room buffer MUST leave them out, so only message content is copied. Every line SHALL map to its owning message.

#### Scenario: Copy a message line
- **WHEN** the user copies the line where Alice's `hi` (sent at 09:12:44) is shown
- **THEN** the kill ring receives `hi`

### Requirement: Date separators
When the date (`%A %B %d, %Y`) changes, a separator SHALL appear: 60 columns with ` <date> ` centred between `─`, starting at column 0 of the text area, with an empty margin. For the first message it goes on line 1, which is otherwise empty. For later messages it goes on its own line above the message header.

#### Scenario: Day change
- **WHEN** consecutive messages are on 22 and 23 November 2026
- **THEN** a separator containing ` Monday November 23, 2026 ` appears before the second message

#### Scenario: Separator layout
- **WHEN** a date separator is shown
- **THEN** its line starts with `─` at column 0 of the text area and has no `├` and no leading spaces

### Requirement: Message body rendering
The body SHALL be `formatted_content` converted to markdown, or else `content`, with NUL characters removed. A reply SHALL be prefixed by `┃ <replied sender>:` and each non-empty replied line as `┃ <line>`, in the comment face. Redacted and state messages SHALL render the whole header line, margin included, in the comment face. State messages have no time or name, and their margin is empty. Edited messages SHALL end their last line with ` (edited)` in the comment face.

#### Scenario: Edited reply
- **WHEN** Bob edits a reply to Alice
- **THEN** the body shows `┃ Alice:` and the quoted lines, then Bob's text ending in ` (edited)`

#### Scenario: Membership line
- **WHEN** Carol joins
- **THEN** a line `Membership: Carol joined the room` appears at column 0 of the text area in the comment face, with an empty margin

#### Scenario: Redacted message
- **WHEN** Bob's message is redacted
- **THEN** the margin shows Bob's time and name and the text area shows `[Redacted]`, all in the comment face

### Requirement: Unread marker
After the message whose id equals `fully_read`, if any visible non-redacted, non-state messages follow it, the buffer SHALL show a 60-column rule containing `  New messages  ` framed by the down-arrow-circle icon, in the separator face. It SHALL start at column 0 of the text area, with an empty margin.

#### Scenario: Only state after marker
- **WHEN** only membership messages follow the fully-read message
- **THEN** no "New messages" marker is shown

#### Scenario: Marker layout
- **WHEN** the "New messages" marker is shown
- **THEN** its line starts with `─` at column 0 of the text area and has no `├` and no leading spaces

### Requirement: Tombstone and typing
A tombstoned room SHALL end with an empty line and then, in the tombstone face, `<body>`, `New room: <replacement>` and `Use M-x neoment-join <replacement> to join the new room.`. When users are typing, a final line `Typing: A, B` in the comment face SHALL appear. These lines SHALL start at column 0 of the text area, with an empty margin.

#### Scenario: Typing users
- **WHEN** Alice and Dave are typing
- **THEN** the last line is exactly `Typing: Alice, Dave`

#### Scenario: Tombstone lines
- **WHEN** the room is tombstoned with replacement `!new:s`
- **THEN** the buffer ends with an empty line, the tombstone body, `New room: !new:s` and `Use M-x neoment-join !new:s to join the new room.`, each starting at column 0 of the text area

### Requirement: Hidden markup characters
When `neoment-room-hide-markup` is non-nil (the default), these SHALL be invisible in room and thread buffers: emphasis markers, inline-code backticks, fence backticks, and a link's `[`, `]` and `(url)`. When it is nil, they SHALL be visible in `neoment-markup`. Re-rendering the buffer (`g`) SHALL apply a changed value.

#### Scenario: Default display
- **WHEN** Alice sends `**this**` at 09:12:44 with the default settings
- **THEN** the margin shows `09:12:44               Alice ` and the text area shows `this` in bold

#### Scenario: Markup shown
- **WHEN** `neoment-room-hide-markup` is nil and the body is `**this**`
- **THEN** the line shows `**this**`, the asterisks in `neoment-markup` and `this` in bold

#### Scenario: Code fence display
- **WHEN** a code block opens with ```` ```elisp ```` with the default settings
- **THEN** the opening fence line shows only `elisp` and the closing fence line shows no text
