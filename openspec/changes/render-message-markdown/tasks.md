# Tasks

## 1. Strikethrough in the converter

- [ ] 1.1 In `neoment-markdown-from-html`, turn `<del>`, `<s>` and `<strike>` into `~~%1~~` before the catch-all tag rule; add tests in `test/neoment-markdown-test.el` for each tag (`<del>old</del> new` → `~~old~~ new`) and verify `make test` passes
- [ ] 1.2 Update the converter description in the `neoment-markdown.el` commentary if it lists the inline tags, and verify `make compile` has no warnings

## 2. Faces and option

- [ ] 2.1 Add `neoment-bold`, `neoment-italic`, `neoment-strike`, `neoment-code`, `neoment-heading` and `neoment-markup` to `neoment-faces.el` as in design.md, and verify `make compile lint` passes
- [ ] 2.2 Add `neoment-room-hide-markup` (boolean, default `t`) to `neoment-config.el`, document it in the README "Options" section, and verify `make compile lint` passes

## 3. Body styling

- [ ] 3.1 Add `neoment-room--style-body` in `neoment-room.el` that propertizes a body string: fenced blocks (fence lines in `neoment-markup` and never invisible, inner lines `neoment-code`), inline code, protected link URLs, headings, then bold/strike/italic with the boundary rules from design.md; markers get `neoment-markup` and `invisible neoment-markup`. Add unit tests in `test/neoment-room-test.el` covering every scenario of the "Inline emphasis", "Code" and "Headings" requirements in the room-timeline delta, and verify they pass
- [ ] 3.2 Call it from `neoment-room--message-lines` on the body and caption before splitting, and on the replied body before adding `┃ ` prefixes; add a render test checking that a reply quote containing `**x**` shows `x` with both `neoment-bold` and the comment face, and verify the existing render tests (`neoment-room-render-example`, `neoment-room-render-properties`) still pass

## 4. Hiding and copying

- [ ] 4.1 In `neoment-room-mode` setup and in `neoment-room-render-buffer`, add `neoment-markup` to `buffer-invisibility-spec` when `neoment-room-hide-markup` is non-nil and remove it otherwise; add a test that renders `**this**` in a room buffer and checks the marker characters are invisible (`invisible-p`) with the option on and visible with it off after `revert-buffer`, and verify it passes
- [ ] 4.2 Add a test that copying the line of a `**this**` message (`filter-buffer-substring`) yields `**this**`, and that cursor position is kept across a re-render on a styled line; verify `make test` passes

## 5. Integration check

- [ ] 5.1 Run `make all` (compile, lint, test) and confirm it passes; then open a room in a GUI Emacs and check a message with bold, italic, inline code, a code block, a heading and a mention renders as specified, with markers hidden and `**` restored on copy
