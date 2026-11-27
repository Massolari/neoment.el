# Design

## Context

`neoment-room-render` builds the whole timeline as one propertized string and inserts it. Each line is a `(TEXT . PROPERTIES)` pair. A header line starts with `neoment-room--header` (time + padded name + ` │ `). Every other line starts with `neoment-room--gutter` (28 spaces + ` │ `). `neoment-room--join-lines` adds a `wrap-prefix` of 29 spaces + `│ ` to every line. Rendering only sees buffer text and text properties; no overlays are used. Navigation (`n`/`p`), image placement and image zoom find header lines through the `neoment-header` text property at the line start. Re-render keeps point by `(message key, character offset)`.

See proposal.md for the motivation and specs/ for the required layout.

## Goals / Non-Goals

**Goals:**
- No line carries a spacing prefix. Every "28" / "31" layout constant goes, except the margin width itself.
- Rendering stays a pure string build: no overlays, no per-window work during render.
- Navigation, the stable re-render and copy filtering keep working without changes to their logic.

**Non-Goals:**
- Changing sender-name truncation (`neoment-room--pad-name`) or the time format.
- Grouping consecutive messages from the same sender.
- Making the margin width configurable, or resizing it to the longest name.
- Making the time and sender searchable with `isearch`.

## Decisions

### Margin text through a `display` text property on a one-character anchor

Each non-state header line starts with one decoration character:

```
(propertize " " 'display `((margin left-margin) ,margin-string)
            'neoment-decoration t)
```

`margin-string` is `HH:MM:SS` + space + padded name + space, with its own faces. The anchor is part of the line text, so it carries the line's `neoment-message` / `neoment-header` properties like everything else.

- *Alternative: overlays with a `before-string`.* These are the usual way to fill margins (linum style). But overlays are not part of the string `neoment-room-render` returns, so they would have to be created after insert, deleted on every re-render, and tests that call `neoment-room-render` would not see them. Rejected.
- *Alternative: a `display` property on the first content character.* A margin display spec replaces the text it sits on, so that character would vanish. Rejected.

The anchor is still real text, so `neoment-room--filter-substring` drops it from copies through `neoment-decoration`. Character offsets inside a message shrink by the removed gutter, but they are computed and resolved by the same code, so the stable re-render is unaffected.

### Margin width from a buffer-local `left-margin-width`

`neoment-room-mode` sets `left-margin-width` buffer-locally to `neoment-room-margin-width` (29), a new constant that replaces `neoment-room-header-width`. Emacs applies it whenever the buffer is shown in a window (`set-window-buffer`), in GUI and terminal frames.

- *Alternative: `set-window-margins` from `window-configuration-change-hook`.* This is only needed when the width changes at runtime, and here it is constant. Rejected as extra code.

29 = 8 (time) + 1 + 19 (name) + 1. The left fringe sits between the margin and the text area by default (`fringes-outside-margins` nil), which adds visual space, so no wider gap is needed.

### Faces of the margin string

The margin string is a separate display string, so the `add-face-text-property` that dims a state or redacted header line does not reach it. `neoment-room--header` builds the margin string and applies `neoment-comment` to it itself when the message is redacted. State messages get no anchor at all, so their margin stays empty.

### Lines without margin text

Continuation lines, reactions, thread bubbles, date separators, the unread marker, tombstone, typing and loading lines all lose their prefix and start at column 0. `neoment-room--gutter` and `neoment-room--wrap-prefix` are deleted, and `neoment-room--join-lines` no longer sets `wrap-prefix`. `neoment-room--separator` stays, because attachment bubbles use it inside their text.

### Images

`neoment-media--image-text` drops its leading spaces. `neoment-media-image-size` uses `(window-width window)`, which already counts only text-area columns (margins excluded), minus 4.

### Test helper for displayed lines

Rendered strings no longer contain the time and name, so tests get a helper that turns a rendered line into what the window shows: the margin string (when the line has an anchor) followed by the text, without the anchor character. The expected-lines fixture then reads `"09:12:44               Alice hi"` for header lines and `"segunda linha ..."` for continuation lines. Tests that only care about the text area compare the buffer text directly.

## Risks / Trade-offs

- [Where the cursor goes on the anchor character is unverified. Point at a header line's start sits on a character that displays in the margin, and Emacs may draw the cursor oddly or let `C-f` look like it does nothing] → The first task is a spike: render one header line, then check cursor display at `bol`, `hl-line`, `C-a`/`C-e`, `n`/`p`, and `current-column` in GUI and `-nw`. If it misbehaves, fall back to overlays with a `before-string` created in `neoment-room-render-buffer` after insert. Spec behavior is the same either way.
- [Another mode that sets the left margin (`olivetti`, `visual-fill-column`, `display-line-numbers` in margin mode) fights over `left-margin-width`] → Accepted. Room buffers already turn off line numbers. Mention it in the proposal impact; no code is needed.
- [`isearch` for a sender name or a time no longer matches] → Accepted in the proposal. Message actions find messages through text properties, not through visible text.
- [`hl-line` highlights the text area only, so the margin of the current line is not highlighted] → Accepted as a small visual change.
- [Thread windows are opened 50 columns wide; with a 29-column margin the text area is 21 columns] → Same usable width as today (50 - 31 = 19, now 21), so no change.
- [Tests that match `.*Bob │` against buffer text break] → Rewritten in the test tasks to use the displayed-line helper.

## Migration Plan

Display-only change with no stored state. Rolling back means reverting the commit; open room buffers pick up the old layout on their next render, or after reopening for the margin width.
