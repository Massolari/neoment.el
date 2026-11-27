# Tasks

## 1. Spike: margin anchor behavior

- [x] 1.1 In a scratch buffer with `left-margin-width` 29, `visual-line-mode` and `hl-line-mode`, insert a line that starts with a `" "` carrying `display ((margin left-margin) "09:12:44               Alice ")` followed by `hi`. Then check, in a GUI frame and in `emacs -nw`: where the cursor is drawn at `bol`; what `C-f` does from `bol`; `C-a`/`C-e`; `current-column` on `h`. Verify by recording the findings in this task's notes. If the cursor or motion is unusable, switch design.md's anchor decision to overlays with a `before-string` before starting group 2.
  - Findings (Emacs 32.0.50, scripted with `posn-at-point`; same in `ns` GUI and `-nw`): `window-margins` is `(29)`. At `bol` point is on the anchor and the cursor is drawn at column 0 of the text area, where `h` is. `C-f` from `bol` moves point onto `h` without moving the cursor on screen (one invisible step). `C-a`/`C-e` behave normally. `current-column` on `h` is 1 (the anchor counts). `C-n`/`C-p` land at visual column 0, i.e. after the anchor on header lines. Usable, so the display-property anchor is kept.

## 2. Timeline margin rendering (`neoment-room.el`)

- [x] 2.1 Add a displayed-line test helper in `test/neoment-room-test.el`. It turns a rendered line into the margin string (when the line has a margin anchor) followed by the text without the anchor. Replace `neoment-room-test-gutter` with it, and rewrite the `neoment-room-render-example` expected lines to the new layout: header lines as `"09:12:44               Alice <text>"`, other lines with no prefix, date separator and unread marker without the 28 spaces + ` ├`. Verify the test now fails against the current renderer.
- [x] 2.2 Add `neoment-room-margin-width` (29) in place of `neoment-room-header-width`, and set `left-margin-width` buffer-locally in `neoment-room-mode`. Verify with a new test that a buffer in `neoment-room-mode` has `left-margin-width` 29, and that a window showing it reports `(car (window-margins))` = 29.
- [x] 2.3 Rewrite `neoment-room--header` so a non-state header returns the one-character margin anchor (display margin string + `neoment-decoration`), with `neoment-comment` applied inside the margin string for redacted messages. State headers return the empty string. Verify with tests for: the short-name, long-name and emoji-width cases (margin string exactly 29 columns, existing `pad-name` expectations kept); a redacted message whose margin string carries `neoment-comment`; and a state line with no margin anchor.
- [x] 2.4 Remove `neoment-room--gutter` and `neoment-room--wrap-prefix`. Drop the gutter from continuation, reaction, thread-bubble, tombstone and typing lines in `neoment-room--message-lines` and `neoment-room-render`, and stop setting `wrap-prefix` in `neoment-room--join-lines`. Verify that `neoment-room-render-example`, the tombstone test and the blank-line test pass with the new expectations, and that no rendered line carries `wrap-prefix`.
- [x] 2.5 Remove the 28 spaces + ` ├` lead-in from `neoment-room--date-separator` and `neoment-room--unread-marker`, so each is just its 60-column rule. Verify by asserting in tests that both lines start with `─` and are 60 columns wide.
- [x] 2.6 Change the initial `Loading...` (in `neoment-room--setup-buffer`) and `Loading thread...` texts to have no gutter prefix. Verify by updating the `Loading...` assertion in `test/neoment-room-test.el` and the `Loading thread...` assertion in `test/neoment-actions-test.el` to the bare strings, and checking they pass.
- [x] 2.7 Update the remaining tests that quote a rendered header (sender-width cases, hidden-markup `line-of` checks, the separator-face check on ` │ hi`, the reply-placeholder line) to use the displayed-line helper, or to assert on the margin string and the text separately. Verify that `make test` passes for `test/neoment-room-test.el`.
- [x] 2.8 Copy check: verify with a test that `filter-buffer-substring` over a rendered header line `hi` returns `hi`, and over a multi-line message returns only its content lines.

## 3. Inline images (`neoment-media.el`)

- [x] 3.1 Drop the leading spaces from `neoment-media--image-text`, and change `neoment-media-image-size` to `window-width - 4`. Verify by updating `test/neoment-media-test.el` (the image column check that uses `neoment-room-header-width`, and the ` *│ caption` match) so it asserts that the image is at the start of its line and the max width is `(window-width) - 4` columns. Check that it passes.
- [x] 3.2 Verify that image zoom (`z` on the header line and on the image line) still finds the image, using the existing zoom tests in `test/neoment-media-test.el`.

## 4. Message actions and navigation

- [x] 4.1 Rewrite the header-line `looking-at` checks in `test/neoment-actions-test.el` (`.*Bob │ ┃ Alice:`, `.*Me │ mine`, and similar) to check the margin string through the displayed-line helper, keeping what each test asserts: which message the cursor is on. Verify that `n`/`p`, reply-goto and thread tests in that file pass.

## 5. Integration

- [x] 5.1 Run `make compile` (byte-compile with warnings as errors), `make lint` and `make test`. Verify all three succeed with no warnings about the removed `neoment-room-header-width`, `neoment-room--gutter` or `neoment-room--wrap-prefix`.
- [ ] 5.2 Manually open a busy room in a GUI frame and in `emacs -nw`. Check that time and name are in the margin, long messages wrap to column 0, images start at column 0, `n`/`p` land on message starts, `M-w` on a line copies only its content, and a re-render (`g`) keeps the cursor on the same message. Record the result in the PR description.
- [x] 5.3 Run `openspec validate render-gutter-in-left-margin --strict` and verify it passes.

## Workflow follow-up

- Archive the change after review, syncing the `room-timeline` and `media-attachments` deltas into the main specs. Update `room-timeline`'s Purpose line ("fixed 31-column gutter") by hand, since a delta doesn't carry it.
