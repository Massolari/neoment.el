# Tasks

## 1. Plain icon preset and per-icon fallback

- [ ] 1.1 Add `neoment-plain-icons` to `neoment-config.el` with the README preset values, covering every key of `neoment-default-icons`. Verify with a new ERT test in `test/neoment-foundation-test.el` asserting both alists have the same key set and every plain value has `string-width` 1.
- [ ] 1.2 Add a displayability cache (hash table keyed by character) and `neoment-icon--clear-cache` in `neoment-config.el`. Make `neoment-icon` return the plain icon only when the selected frame is graphical, the value is `equal` to the default for that key, and some character fails `char-displayable-p`. Verify with ERT tests (using `cl-letf` on `display-graphic-p` and `char-displayable-p`, as in `neoment-faces-bubble-edge-fallback`) for these cases: default and undisplayable gives `#`; customised and undisplayable gives the user value; displayable gives `\U000F0BA7`; tty gives `\U000F0BA7`; `neoment-icons` set to `neoment-plain-icons` gives `#`.
- [ ] 1.3 Clear the icon cache from `neoment-faces--update`. Verify with an ERT test: populate the cache, call the update, and assert the cache is empty.

## 2. Nerd Font fontset routing

- [ ] 2.1 Add `defcustom neoment-icon-font-family` (type `(choice (const :tag "Disabled" nil) string)`, default `"Symbols Nerd Font Mono"`) with a `:set` that resets the applied-family guard. Verify `make compile` passes with no warnings.
- [ ] 2.2 Implement `neoment-faces-setup-icon-font` in `neoment-faces.el` as in design decision 1. It returns early on a tty, a `nil` family, a missing font (`find-font`) or a family that is already applied. It collects private-use characters (`#xE000–#xF8FF`, `#xF0000–#xFFFFD`) from `neoment-icons`, `neoment-default-icons` and the bubble edges, calls `set-fontset-font t CHAR (font-spec :family F) nil 'append` for each one, then clears the icon cache. Verify with ERT tests that stub `set-fontset-font`, `find-font` and `display-graphic-p`. Assert that U+F0BA7 and U+E0B6 are routed with `append`, that ASCII/BMP non-PUA characters like `▶` are not, and that nothing is called when the family is `nil`, the font is missing, the frame is a tty, or on a second call.
- [ ] 2.3 Call `neoment-faces-setup-icon-font` at the start of `neoment-faces-bubble-edges` and in the room pickers (`neoment-rooms.el`, near line 890). Verify with an ERT test that `neoment-faces-bubble-edges` invokes it in a GUI frame. Then run `make test` and check that the existing bubble-edge tests still pass.

## 3. Documentation and spec alignment

- [ ] 3.1 Update `README.md` "Icons and fonts": explain the automatic Nerd Font routing and `neoment-icon-font-family`, replace the inline preset with `(setq neoment-icons neoment-plain-icons)`, and add `neoment-icon-font-family` to the options table. Update the "Squares instead of icons" troubleshooting entry to mention the option and installing `Symbols Nerd Font Mono`. Verify by reading the README section and confirming the snippet evaluates in `emacs -Q -L .` after `(require 'neoment-config)`.
- [ ] 3.2 Run `make all` (compile, lint, test) and `openspec validate fix-material-icon-display --strict`. Both must pass.

## 4. Manual check in a GUI frame

- [ ] 4.1 With `Iosevka` as the default font and `Symbols Nerd Font Mono` installed, open `M-x neoment` in a GUI frame. Confirm the room icon shows `󰮧` and not a `0F0BA7` box, and that `(font-at POS)` on it reports `Symbols Nerd Font Mono`. Then set `neoment-icon-font-family` to a family that isn't installed, restart Emacs, and confirm room lines show `#`.

## Workflow follow-up

- Archive the change after review, which syncs the two new requirements into `openspec/specs/client-configuration/spec.md`.
