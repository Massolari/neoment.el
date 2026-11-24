# Tasks

## 1. Strikethrough in the converter

- [x] 1.1 In `neoment-markdown-from-html`, turn `<del>`, `<s>` and `<strike>` into `~~%1~~` before the catch-all tag rule; add tests in `test/neoment-markdown-test.el` for each tag (`<del>old</del> new` → `~~old~~ new`) and verify `make test` passes

## 2. Faces and option

- [x] 2.1 Add `neoment-bold`, `neoment-italic`, `neoment-strike`, `neoment-code`, `neoment-heading`, `neoment-markup` and `neoment-link` to `neoment-faces.el` as in design.md, and verify `make compile lint` passes
- [x] 2.2 Add `neoment-room-hide-markup` (boolean, default `t`) to `neoment-config.el`, document it in the README "Options" section, and verify `make compile lint` passes

## 3. Body styling

- [x] 3.1 Add `neoment-room--style-body` in `neoment-room.el` with steps 2–5 of the design scan (inline code, links with mention/emoticon/spoiler handling and `help-echo`/`mouse-face`/`neoment-link` properties, headings, emphasis with boundary rules); markers get `neoment-markup` + `invisible neoment-markup`. Move mention/emoticon detection out of `neoment-room--style-line`, keeping its quote face. Add unit tests in `test/neoment-room-test.el` for every scenario of the "Inline emphasis", "Inline code", "Headings" and "Links" requirements, and verify they and the existing mention/emoticon/hover tests pass
- [x] 3.2 Add fenced-block handling (step 1): fence backticks as markers, language name in `neoment-markup`, inner lines `neoment-code`, protected from later steps; test the "Unknown or missing language" scenario and verify it passes
- [x] 3.3 Add code fontification: language→mode alias table, reused hidden buffer with `delay-mode-hooks` + `font-lock-ensure`, copying `face`/`font-lock-face`, capped cache keyed by `(mode . code)`, fallback to `neoment-code` on unknown mode or error; test the "Known language" scenario with `emacs-lisp-mode`, a cache-hit test, and an erroring-mode fallback test, and verify they pass
- [x] 3.4 Call `neoment-room--style-body` from `neoment-room--message-lines` on the body and caption before splitting, and on the replied body before adding `┃ ` prefixes; add a render test checking that a reply quote containing `**x**` shows `x` with both `neoment-bold` and the comment face, and verify the existing render tests (`neoment-room-render-example`, `neoment-room-render-properties`) still pass

## 4. Hiding and copying

- [x] 4.1 In `neoment-room-mode` setup and in `neoment-room-render-buffer`, add `neoment-markup` to `buffer-invisibility-spec` when `neoment-room-hide-markup` is non-nil and remove it otherwise; add a test that renders `**this**`, a mention and a ```` ```elisp ```` fence in a room buffer and checks markers/URLs/backticks are `invisible-p` with the option on and visible after setting it nil and `revert-buffer`, and verify it passes
- [x] 4.2 Add tests that copying (`filter-buffer-substring`) the line of a `**this**` message yields `**this**` and of a mention yields the full `[Alice](https://matrix.to/#/@alice:s)`, and that the cursor stays on the same message and offset across a re-render on a styled line; verify `make test` passes

## 5. Opening links

- [x] 5.1 In `neoment-room-open-attachment` (`neoment-media.el`), check the `neoment-link` property at point first: spoilers show their content via `neoment-notify--message`, other non-`mxc://` URLs go to `browse-url`, otherwise fall through to the existing logic; bind mouse-1 in the link text keymap to the same command at the click position. Add tests in `test/neoment-media-test.el` for the "Open a link" and "Reveal a spoiler" scenarios (stubbing `browse-url`) plus the unchanged emoticon/attachment paths, and verify they pass
- [x] 5.2 Update the README room-keys table so `o` reads "open the link, attachment or emoticon at point", and verify the README renders as a valid table

## 6. Integration check

- [ ] 6.1 Run `make all` (compile, lint, test) and confirm it passes; then open a room in a GUI Emacs and compare against neoment.nvim on the same messages: bold, italic, strike, inline code, an elisp code block, a heading, a mention, a link and a spoiler should show the same visible text, `o` should open the link and reveal the spoiler, and copying should return the markdown
