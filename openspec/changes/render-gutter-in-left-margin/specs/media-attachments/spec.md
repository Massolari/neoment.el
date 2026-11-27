# Spec Delta

## MODIFIED Requirements

### Requirement: Inline images
In GUI frames, image attachments (or thumbnails) SHALL render on their own line directly below the message header, starting at column 0 of the text area, with an empty margin. Maximum width is `text area width - 4` (the left margin is not part of the text area) and the default maximum height is 20% of window height, both capped by the real image size. If the buffer re-renders before the download finishes, the image SHALL be dropped. In terminal frames only the bubble shows.

#### Scenario: Terminal frame
- **WHEN** an image message is shown in `emacs -nw`
- **THEN** only the `󰋩  Image: <file>` bubble is displayed

#### Scenario: Image position and width
- **WHEN** a large image message is shown in a GUI window whose text area is 80 columns wide
- **THEN** the image line starts with the image at column 0 of the text area, and the image is at most 76 columns wide
