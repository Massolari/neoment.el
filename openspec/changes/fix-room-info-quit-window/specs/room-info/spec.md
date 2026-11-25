# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Avatar actions
`o` SHALL open the avatar with the attachment handler (origin `avatar`), or show `No avatar image to open`. `z` SHALL toggle the avatar between 16×8 and window size, or show `No avatar image to zoom`. Only `mxc://` avatars are downloaded. `f`/`F` open the pickers.

#### Scenario: No avatar
- **WHEN** the room has no avatar and the user presses `o`
- **THEN** `No avatar image to open` is shown
