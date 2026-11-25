# Design

## Context

`neoment-room--pad-name` (`neoment-room.el:149`) currently does:

```elisp
(let ((name (truncate-string-to-width name neoment-room-name-width)))
  (concat (make-string (- neoment-room-name-width (string-width name)) ?\s) name))
```

`truncate-string-to-width` adds up per-character `char-width`. `string-width` (Emacs 29+) measures auto-composed grapheme clusters. For `❤` + U+FE0F, the per-character sum is 1 but the composed width is 2, so a name of such emoji is "truncated" to 19 per-character columns while it actually displays far wider. The padding goes negative and `make-string` signals `wholenump`. The error escapes the render function that `neoment-ui-flush` runs from its idle timer, so the room buffer never draws. Each sync reschedules the render, which is why the message repeats ("[4 times]"). The mismatch can also go the other way (ZWJ sequences measure narrower than their per-character sum), which only over-truncates without erroring.

## Goals / Non-Goals

**Goals:**
- The name column is never wider than 19 displayed columns, and the padding is never negative.
- Glyphs (emoji, ZWJ sequences, combining marks) are never split.
- Plain-ASCII behaviour stays byte-for-byte identical.

**Non-Goals:**
- Fixing the same counting mismatch in `neoment-rooms--truncate` (room list; it overflows cosmetically but cannot error).
- Making `neoment-ui-flush` keep going after a render function fails. Worth considering separately, but here it would only hide this bug.
- Pixel-accurate alignment for fonts whose emoji glyphs don't match their `string-width`.

## Decisions

1. **Truncate by glyphs, measured with `string-width`.** Walk the name glyph by glyph, finding each composed glyph's end with `find-composition-internal` (always advancing at least one character), and keep a running total of each glyph's `string-width` while it stays ≤ 19; then take one `substring`. This uses the same width function as the padding arithmetic, so the two can't disagree, a cluster is never cut, and the cost is linear in the name's length.
   - *Alternative:* `string-glyph-split`. Rejected: it loops forever when a multi-codepoint emoji (VS16, skin tone, flag, ZWJ) is followed by more text, because its composition lookup can return a glyph ending at the current position.
   - *Alternative:* keep `truncate-string-to-width`, then drop characters from the end while `string-width` > 19. Rejected because dropping characters can leave a stray ZWJ or variation selector, giving broken glyphs.
   - *Alternative:* `string-pixel-width`. Rejected: it needs a window and font, depends on the display, and doesn't work in batch tests or terminals.
   - *Fast path:* when `(string-width name)` ≤ 19 already, use the name unchanged. This avoids walking glyphs on every header and keeps ASCII output identical.
2. **Clamp the padding with `(max 0 …)`** as a safety net, matching the guard every other `make-string` call site in the codebase already uses (`neoment-room--rule`, `neoment-rooms--title-line`, `neoment-room-info--title`).

## Risks / Trade-offs

- [`string-width` may not match what a given font actually draws for some emoji] → Alignment could be off by a column in that font, but no error can happen because of the clamp. This is acceptable and already true today for short names.
- [Splitting on every long header costs time] → Only names wider than 19 columns are split, and names are short, so the cost is negligible.
