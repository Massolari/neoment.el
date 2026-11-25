# Spec Delta

## MODIFIED Requirements

### Requirement: Unread rule
A room SHALL be unread when `unread` is set manually, or when it has unread activity and neither the read receipt nor `fully_read` is at or after it. A marker is at or after the unread activity when it points at the same event, or when its event is loaded with a timestamp greater than or equal to the unread activity's. When the receipt's event is not loaded, the receipt's `ts` SHALL be compared instead. A `fully_read` event that is not loaded SHALL NOT count.

#### Scenario: Unread with zero counts
- **WHEN** notification counts are 0 and neither the receipt nor fully_read is at or after the unread activity
- **THEN** the room is unread

#### Scenario: Marker on the same event
- **WHEN** the read receipt or fully_read points at the unread activity event
- **THEN** the room is read

#### Scenario: Receipt on a later event
- **WHEN** another client moved the user's receipt to a loaded state event newer than the unread activity
- **THEN** the room is read

#### Scenario: Receipt event not loaded
- **WHEN** the receipt points at an event that is not loaded and its `ts` is later than the unread activity's timestamp
- **THEN** the room is read

#### Scenario: Older receipt
- **WHEN** the receipt points at a loaded event older than the unread activity and fully_read is not at or after it
- **THEN** the room is unread

#### Scenario: Fully read event not loaded
- **WHEN** fully_read points at an event that is not loaded and the receipt is not at or after the unread activity
- **THEN** the room is unread

#### Scenario: No unread activity
- **WHEN** the room has no unread activity and `unread` is not set
- **THEN** the room is read

#### Scenario: Manually marked unread
- **WHEN** `unread` is set and the receipt is on the unread activity
- **THEN** the room is unread

### Requirement: Ordering and last activity
Messages SHALL be sorted by ascending `timestamp`, and on a tie by larger `age` first. Last activity SHALL update when the timestamp is greater, or equal with a smaller `age`. Unread activity SHALL follow the same rule but only for messages and stickers that are not thread replies and not sent by the user.

#### Scenario: Timestamp tie
- **WHEN** two messages share a timestamp with ages 500 and 100
- **THEN** the age-500 message is ordered first

#### Scenario: Own message
- **WHEN** the room is read and a message sent by the user arrives, from neoment or another device
- **THEN** last activity moves to the message, unread activity does not, and the room stays read

#### Scenario: Thread reply
- **WHEN** the room is read and another user's thread reply arrives
- **THEN** last activity moves to the reply, unread activity does not, and the room stays read

#### Scenario: Main timeline message from another user
- **WHEN** another user's message that is not a thread reply arrives after the receipt
- **THEN** both last activity and unread activity move to it, and the room is unread
