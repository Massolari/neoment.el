# message-actions Specification

## Purpose

Defines the commands a user runs on the message under the cursor in a room or thread buffer: navigate, react, redact, edit, reply, forward, open threads, jump to the replied message, set the read marker and inspect the raw event.

## Requirements

### Requirement: Message under cursor
Message actions SHALL act on the message that owns the current line. When there is none they SHALL show `No message under the cursor`.

#### Scenario: Action on date separator
- **WHEN** the user presses `r` on a date separator line
- **THEN** `No message under the cursor` is shown

### Requirement: Room mode key bindings
`neoment-room-mode` SHALL bind:
- `RET` compose, `r` reply, `e` edit, `t` thread
- `n`/`p` next/previous message
- `a`/`A` react (emoji/text), `d` redact, `w` forward
- `R` go to replied message, `m` set read marker, `V` show event
- `P` load previous, `L` leave
- `o`/`s` open/save attachment, `u`/`U` upload/upload clipboard, `z` zoom
- `i` info, `N` notification settings
- `f`/`F` pickers, `l` toggle the room list
- `q` quit, `g` revert

Each key SHALL call a named interactive command.

#### Scenario: Remap
- **WHEN** the user binds another key to `neoment-room-reply` in `neoment-room-mode-map`
- **THEN** that key starts a reply

### Requirement: Message navigation
`n`/`p` SHALL move to the header line of the next/previous message, skipping the current message's other lines and state messages. With no more messages: `No more messages in this direction`.

#### Scenario: Skip state messages
- **WHEN** a membership line sits between two messages and the user presses `n` on the first
- **THEN** the cursor lands on the second message's header

### Requirement: Reactions toggle
`a` SHALL prompt `Select reaction: ` over the emoji table (label → character), and `A` SHALL prompt `Enter reaction: ` for free text. If the user already reacted with that key, the client SHALL redact that reaction. Otherwise it SHALL send `m.reaction` with `m.annotation` on the message's effective id.

#### Scenario: Remove own reaction
- **WHEN** the user picks 👍 on a message they already reacted 👍 to
- **THEN** their reaction event is redacted and no new reaction is sent

### Requirement: Redact
`d` SHALL prompt `Redact message reason: `. Cancelling aborts, and an empty reason is allowed. It then sends `PUT /rooms/<r>/redact/<id>/<txn>` with `{reason}`. Errors show `Error redacting message: <e>`.

#### Scenario: Empty reason
- **WHEN** the user submits an empty reason
- **THEN** the redaction is sent with an empty reason

### Requirement: Edit and reply entry
`e` SHALL open the compose buffer in edit mode, only for the user's own messages; otherwise it shows `You can only edit your own messages`. `r` SHALL open compose in reply mode. `RET` SHALL open compose for a new message, which goes to the thread when used in a thread buffer.

#### Scenario: Edit someone else's message
- **WHEN** the user presses `e` on Bob's message
- **THEN** `You can only edit your own messages` is shown

### Requirement: Threads
`t` on a thread root or thread reply SHALL open or focus the thread buffer `neoment://thread/<root_id>/sender/<author name>` in a window to the right. The buffer starts as `Loading thread...`. On a message outside a thread, `t` SHALL open compose to start a thread on it.

#### Scenario: Start thread
- **WHEN** the user presses `t` on a message with no thread
- **THEN** compose opens titled `Sending to thread in <room>`

### Requirement: Go to replied message
`R` SHALL jump to the replied message (matched by id or `edit_data.id`) after pushing the mark, and show `Found replied message`. On a message that is not a reply it shows `This message is not replying to another message`.

#### Scenario: Replied message loaded
- **WHEN** the replied message is in the buffer
- **THEN** the cursor moves to it and `C-u C-SPC` returns to the reply

### Requirement: Load history to find replied message
When the replied message is not loaded, `R` SHALL ask `The replied message is older than the loaded messages. Load more messages?`, load a page and retry. Each time it is still missing it asks `The replied message was not found. Load more messages?`. When history is exhausted it shows `The replied message was not found in the room history`.

#### Scenario: Found after one page
- **WHEN** the replied message arrives with the next history page
- **THEN** the cursor jumps to it after the user confirms once

#### Scenario: History exhausted
- **WHEN** `prev_batch` reaches `End` without finding the message
- **THEN** `The replied message was not found in the room history` is shown

### Requirement: Set read marker
`m` SHALL send `read` and `fully_read` for the message under the cursor and re-render, moving the "New messages" marker.

#### Scenario: Move marker back
- **WHEN** the user presses `m` on an older message
- **THEN** the "New messages" marker appears after that message

### Requirement: Forward
`w` SHALL prompt `Forward to room: ` and send the message's content (markdown, derived from HTML when present) and its attachment (same `mxc_url`, no re-upload) to the chosen room. It then shows `Message forwarded to <room>` and opens that room.

#### Scenario: Forward image
- **WHEN** an image message is forwarded
- **THEN** the new event reuses the original `mxc://` URL

### Requirement: Show raw event
`V` SHALL show the message's raw event as indented JSON in a pop-up buffer titled `Event: <id>`, closed with `q`. Without an event it shows `Event not found for this message`.

#### Scenario: State message without event
- **WHEN** the underlying raw event is not stored
- **THEN** `Event not found for this message` is shown

### Requirement: Room info and quit
`i` SHALL open or focus room info in a window to the right, 50 columns wide. `q` SHALL kill the room buffer. `P` SHALL load more history.

#### Scenario: Quit
- **WHEN** the user presses `q`
- **THEN** the room buffer is killed and the room is untracked
