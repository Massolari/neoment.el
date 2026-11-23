# Spec Delta

## Purpose

Gives the user a markdown compose buffer for writing new messages, replies, thread messages, edits and attachment captions, with mention completion. It also defines the exact Matrix events sent for each case.

## ADDED Requirements

### Requirement: Compose window
The compose buffer SHALL be temporary and open in a fixed window 10 lines high below the room window, with word wrap, no line numbers and a highlighted current line. Closing it SHALL give the height back to the room window and return focus to it.

#### Scenario: Cancel compose
- **WHEN** the user presses `C-c C-k`
- **THEN** the compose buffer is killed and the room window gets focus and its original height back

### Requirement: Compose buffer naming
The buffer name SHALL be one of:
- `neoment://compose/Sending to <room>`
- `neoment://compose/Sending to thread in <room>`
- `neoment://compose/Replying to <sender>`
- `neoment://compose/Editing message on <room>`

Each gets the suffix ` with the attachment <filename>` when an attachment is attached.

#### Scenario: Reply with attachment
- **WHEN** the user uploads `a.png` while replying to Alice
- **THEN** the buffer is named `neoment://compose/Replying to Alice with the attachment a.png`

### Requirement: Initial content
Edit mode SHALL prefill the message `content` (non-empty lines) with point at the end. Other modes start empty and focused. The buffer SHALL have markdown highlighting.

#### Scenario: Edit prefill
- **WHEN** the user edits a message with content `hello\nworld`
- **THEN** the compose buffer contains those two lines and point is at the end

### Requirement: Mention completion
After `@`, `completion-at-point` SHALL offer the room's members except the user, matched case-insensitively against user id or display name. It inserts the user id, annotated with the display name.

#### Scenario: Complete by display name
- **WHEN** the user types `@ali` and Alice is `@alice:s`
- **THEN** `@alice:s` is offered with annotation `Alice`

### Requirement: Send and cancel keys
`C-c C-c` SHALL send and `C-c C-k` SHALL cancel. Sending joins lines with `\n`, does nothing if the text is empty and there is no attachment, and otherwise sends and closes. Errors show `Error sending message: <e>`.

#### Scenario: Empty send
- **WHEN** the buffer is empty and there is no attachment
- **THEN** nothing is sent and the buffer stays open

### Requirement: Text message event
A message SHALL be sent as `PUT /rooms/<r>/send/m.room.message/<txn>` with a unique per-client txn prefix. The content is `{msgtype:"m.text", body:<raw markdown>, format:"org.matrix.custom.html", formatted_body:<html>, "m.mentions":{user_ids}}`. In the HTML, `@user:server` (regex `@[a-zA-Z0-9_-]+:[^\s]+`) SHALL become a `matrix.to` link with the display name, and be listed in `m.mentions`, only when the display name is known (differs from the id).

#### Scenario: Known mention
- **WHEN** the body is `hi @alice:s` and Alice's display name is known
- **THEN** `formatted_body` links `https://matrix.to/#/@alice:s` with text `Alice`, and `m.mentions.user_ids` contains `@alice:s`

#### Scenario: Unknown mention
- **WHEN** the mentioned user's display name is unknown
- **THEN** the id stays plain text and is not in `m.mentions`

### Requirement: Reply and thread relations
A reply SHALL add `m.relates_to.m.in_reply_to.event_id = <effective id>`. A thread message SHALL set `m.relates_to = {rel_type:"m.thread", event_id:<root>, is_falling_back:true}`, also with `m.in_reply_to` when it is a reply.

#### Scenario: Reply to edited message
- **WHEN** replying to a message that was edited
- **THEN** `in_reply_to.event_id` is the original event id

### Requirement: Edit event
An edit SHALL send `{msgtype:"m.text", body:"* "+body, "m.new_content":<the text message content>, "m.relates_to":{rel_type:"m.replace", event_id:<edit_data.id or id>}}`.

#### Scenario: Edit body
- **WHEN** the user edits a message to `fixed`
- **THEN** the event body is `* fixed` and `m.new_content.body` is `fixed`

### Requirement: Attachment message
With an attachment, `msgtype` SHALL come from the mimetype (`image/*` → `m.image`, `video/*` → `m.video`, `audio/*` → `m.audio`, otherwise `m.file`). It includes `filename`, `url` (mxc) and `info {mimetype, size}`. The typed text is the body (caption).

#### Scenario: PDF upload
- **WHEN** the attachment mimetype is `application/pdf`
- **THEN** `msgtype` is `m.file`

### Requirement: Own message not new
After a successful send, the room's `fully_read` SHALL be set to the returned event id, so the user's own message never shows as new.

#### Scenario: Send then render
- **WHEN** the user sends a message
- **THEN** no "New messages" marker appears above it
