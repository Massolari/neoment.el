# Proposal

## Why

Inline images are drawn as an overlay `after-string` on the message header line, so the cursor can never rest on them. `z` therefore works from the header line *above* the image. That design came over from the Neovim client, where virtual lines leave no other choice. Emacs can do better: ement.el puts the image in the buffer text, so the cursor can land on it and image-specific keys work there. Doing the same here makes images feel like first-class content and leaves room for more image actions.

## What Changes

- Inline images become real (read-only) buffer text: a line under the message header made of the 31-column indent plus one character displaying the image. The cursor can move onto it with `C-n`/`C-p`/`next-line`. The line belongs to its message, so `r`, `e`, `a`, `s` and the other message actions still work from it. It is a decoration, so it stays out of copied text.
- The image carries its own keymap, active only while the cursor is on it:
  - `z` toggles zoom between the default 20% and 100% of the window height.
  - `+` / `-` enlarge or shrink the image one step (×1.25 / ÷1.25 of its height budget, between 5% and 100% of the window height).
  - `o` opens the full image in a dedicated buffer in `image-mode`, which brings Emacs's own zoom, fit, rotate and save commands. For video or location thumbnails, `o` keeps the normal open-attachment behaviour.
- `z` on the message header line keeps working as it does today, so muscle memory carries over. Elsewhere it still shows `No image on this line`.
- Re-renders (sync, typing, reactions) keep the cursor on the image it was on. They also keep each image's zoom and size for as long as the buffer lives.

No breaking changes. Terminal frames are unaffected: they still show only the bubble.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `media-attachments`: "Inline images" changes from an overlay after the header to a focusable image line. "Image zoom" now works on the image itself as well as on the header line. New requirements cover image resizing (`+`/`-`), opening an image in `image-mode` (`o` on the image), and keeping the cursor on an image across re-renders.

## Impact

- `neoment-media.el`: `neoment-media--place-image`, `neoment-media-add-images` and `neoment-room-toggle-image-zoom` are reworked. It gains a new image keymap and commands (`neoment-room-image-enlarge`, `neoment-room-image-shrink`, `neoment-room-image-open`) and per-message size state.
- `neoment-room.el`: `neoment-room-render-buffer` places images before it restores point and window anchors. The per-buffer state `neoment-room--zoomed` becomes a size table.
- `test/neoment-media-test.el`: new tests for placement, focus preservation, zoom, resize and opening in `image-mode`.
- `README.md`: document the image keys.
- No new dependencies. `image-mode` ships with Emacs.
