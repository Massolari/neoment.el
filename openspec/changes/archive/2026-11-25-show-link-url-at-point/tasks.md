# Tasks

## 1. Link text helper

- [x] 1.1 Add `neoment-media-link-echo-text (props)` to `neoment-media.el`. It returns the `neoment-link` URL, or nil when `neoment-spoiler` or `neoment-emoticon` is set or there is no link. Verify with a new ERT test in `test/neoment-media-test.el` covering plain link, mention, spoiler (nil), emoticon (nil) and plain text (nil).
- [x] 1.2 Add an end-to-end ERT test: render `see [docs](https://example.org)` with `neoment-room-render`, take the properties at `docs` in the rendered text, and check that the helper returns `https://example.org`. For `[Spoiler](<the end>)` it returns nil. Verify with `make test`.

## 2. Show the URL at point

- [x] 2.1 In `neoment-media--show-popup`, when `neoment-media-popup-text` returns nil, call the helper. If it returns a URL and no minibuffer is active, show it with `message` with `message-log-max` bound to nil. Never use posframe for it. Verify with an ERT test that stubs `message`, calls `neoment-media--show-popup` on link text, and asserts `https://example.org` is shown and `*Messages*` gains no line.
- [x] 2.2 Add ERT tests: a spoiler shows nothing, an emoticon link still yields the emoticon popup text, and plain text shows nothing. Verify with `make test`.
- [x] 2.3 Mention the link behaviour in the README's hover/popup section and update the `neoment-media--show-popup` docstring. Verify `make compile lint` passes with no warnings.

## 3. Integration check

- [ ] 3.1 Manual check in `emacs -nw` and in a GUI frame: rest the cursor on a link and see the URL in the echo area after about 0.5 s. A spoiler shows nothing, an emoticon shows its popup, and a mouse hover still shows the tooltip. Run the full `make` (compile, lint, test) green.

## Workflow follow-up

- Archive the change after review; the archive adds "Link URL at point" to `openspec/specs/room-timeline/spec.md`.
