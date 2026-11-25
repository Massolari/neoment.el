# Proposal

## Why

Opening some rooms fails with `Error running timer 'neoment-ui-flush': (wrong-type-argument wholenump -5)`, and the room never renders. The cause is a sender display name with emoji followed by variation selector 16 (e.g. `❤️`). `truncate-string-to-width` counts each such pair as 1 column, but `string-width` measures the composed glyph as 2. The name column's padding, `(- 19 (string-width name))`, then goes negative and `make-string` signals an error. Reproduced in Emacs batch mode: twenty `❤️` give a padding of −18, and five of them give −5.

## What Changes

- Truncate the sender name in the message header line by its *displayed* width, measured on whole glyphs (grapheme clusters). Truncated names then never exceed 19 columns and an emoji is never cut in half.
- Never pad with a negative count: the padding is clamped to zero as a safety net for any remaining width mismatch.
- Add regression tests for names with VS16 emoji, ZWJ sequences, and wide (CJK/fullwidth) characters, so the gutter stays exactly 31 columns wide.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `room-timeline`: adds a "Sender name display width" requirement. The existing "Message header line" requirement's 19-column name limit is measured in displayed width, including composed emoji, and rendering must not fail for any display name.

## Impact

- `neoment-room.el`: `neoment-room--pad-name` (only caller of the faulty arithmetic). All other `make-string` call sites were checked and are already clamped or use constants.
- `test/neoment-room-test.el`: new regression tests.
- No API, dependency, or data changes. `find-composition-internal` and `string-width` with FROM/TO are available in Emacs 29.1, the package's minimum version.
- Out of scope: `neoment-rooms--truncate` in `neoment-rooms.el` has the same counting mismatch, but it only appends "…" and never pads, so it can overflow by a few columns but cannot raise this error.
