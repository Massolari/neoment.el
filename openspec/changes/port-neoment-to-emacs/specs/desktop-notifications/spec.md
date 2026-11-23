# Spec Delta

## Purpose

Alerts the user through the operating system when relevant messages arrive. It follows the server's push rules, and never notifies for noise such as the initial sync or the user's own messages.

## ADDED Requirements

### Requirement: Suppression rules
Desktop notifications MUST NOT fire when:
- they are disabled
- during the first sync
- for the user's own messages or for state messages
- for the room shown in the current buffer while Emacs has focus

#### Scenario: Initial sync
- **WHEN** the first sync brings 100 unread messages
- **THEN** no desktop notification is sent

#### Scenario: Focused room
- **WHEN** a message arrives for the room in the selected window and the Emacs frame has focus
- **THEN** no notification is sent

### Requirement: Notification text
The title SHALL be the sender name when it equals the room name (DM). Otherwise it is `[<room>] <sender>`. The body SHALL be the message content.

#### Scenario: Group message
- **WHEN** Alice writes "hi" in room "dev"
- **THEN** the title is `[dev] Alice` and the body `hi`

### Requirement: Push-rule notifications
The client SHALL notify when a room's notification or highlight count increases. It uses that sync's newest incoming message for the room (the candidate). Without one, it uses the newest stored message after the read receipt and the room's last notification. If there is none, the title is the room name and the body `New notification`. Candidates clear at the start and end of each sync.

#### Scenario: Count increases without message
- **WHEN** a room's notification_count rises but no message for it is known
- **THEN** a notification titled with the room name and body `New notification` is sent

#### Scenario: Client replaced
- **WHEN** the user logs out and logs in again
- **THEN** per-room last-notification state and candidates are reset

#### Scenario: Count unchanged
- **WHEN** a message arrives but the counts do not increase
- **THEN** no notification is sent

### Requirement: Default handlers
The default handler SHALL use:
- Linux/BSD: D-Bus `notifications-notify` with app name `Neoment`, warning once if D-Bus is unavailable
- macOS: `osascript` `display notification` with title `Neoment` and the computed title as subtitle, passing the texts as arguments and never interpolating them into the script
- Windows: `w32-notification-notify`

The handler SHALL be customisable.

#### Scenario: Quotes in message on macOS
- **WHEN** a message body contains `"; do shell script "x`
- **THEN** the text is shown literally and nothing is executed
