# Proposal

## Why

The room timeline draws its 31-column time/sender gutter as real buffer text. Every non-header line therefore has to carry a 28-space + ` │ ` prefix, soft-wrapped lines need a matching `wrap-prefix`, and the number 28 or 31 is hard-coded in about ten places (date separator, unread marker, loading text, tombstone, typing line, image column and image width). Emacs can show this column in the window's left margin instead. Content then starts at column 0 of the text area, and wrapping is right without any prefix.

## What Changes

- The time and sender name of each non-state message's header line SHALL be shown in the window's left margin, not inserted as buffer text. The margin is a fixed width: `HH:MM:SS`, a space, the 19-column right-aligned sender name, and one trailing space (29 columns).
- **BREAKING (visual)**: the text bar `│` between the gutter and the content is replaced by a 2-pixel bar drawn in the window's left fringe, between the margin and the text area. It runs the full height of the window, including soft-wrapped rows and image rows. Terminal frames have no fringe, so they show no bar. Continuation lines, reactions, thread bubbles, state messages, tombstone and typing lines start at column 0 of the text area, with no prefix. Soft-wrapped lines have no `wrap-prefix`.
- **BREAKING (visual)**: date separators and the unread marker lose their 28-space + ` ├` lead-in. They become the existing 60-column rules, starting at column 0 of the text area.
- The initial `Loading...` and `Loading thread...` texts lose their gutter prefix.
- Inline images start at column 0 of the text area. Their maximum width becomes `text area width - 4`.
- Sender-name truncation and right-alignment to 19 columns (displayed width, whole glyphs) are unchanged. They now apply to the margin text.
- Time and sender stay excluded from copies (they are no longer buffer text at all).
- The time and sender name are no longer buffer text, so `isearch` and other buffer-text searches no longer match them. This is accepted.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `room-timeline`: buffer display (margin, no wrap-prefix), a new fringe-bar requirement, initial loading text, message header line layout, sender-name width wording, decoration/copy wording, date separators, body rendering (membership-line scenario), unread marker, tombstone and typing, and the hidden-markup scenarios that quote a rendered line.
- `media-attachments`: the inline image column and maximum width.

## Impact

- `neoment-room.el`:
  - `neoment-room--header`, `neoment-room--gutter`, `neoment-room--wrap-prefix`, `neoment-room--date-separator`, `neoment-room--unread-marker`, `neoment-room--message-lines`, `neoment-room--join-lines` and `neoment-room-render` (tombstone and typing).
  - The `Loading...` texts in `neoment-room--setup-buffer` and `neoment-room-open-thread-buffer`.
  - Setting the margin width, the left fringe width and the `fringe` face remap in `neoment-room-mode`.
  - `neoment-room-header-width` is replaced by a margin-width constant.
- `neoment-faces.el`: a new `neoment-room-bar` face for the fringe bar.
- `neoment-media.el`: `neoment-media-image-size`, `neoment-media--image-text`.
- Tests: `test/neoment-room-test.el` (expected-lines fixture, gutter helper, header and loading assertions), `test/neoment-actions-test.el` (header-line `looking-at` checks and thread loading text), `test/neoment-media-test.el` (image column and caption checks). Tests need a helper that shows a line as displayed, margin included.
- Users: a third-party mode that also sets the left margin on room windows (for example `olivetti` or `visual-fill-column`) may conflict with this one. So may a mode that sets the left fringe width.
