# Tasks

Each group ships its own ERT tests. `make test`, `make compile` (no warnings) and `make lint` must stay green at the end of every group. ERT tests that need images run only when `(display-images-p)` holds or stub `create-image`. GUI-only behaviour gets a manual check.

## 1. Height state and size computation

- [x] 1.1 Replace `neoment-room--zoomed` in `neoment-room.el` with the buffer-local alist `neoment-room--image-heights` (key → fraction of window height; missing = 0.2). Add the helpers `neoment-media--image-fraction`/`neoment-media--set-image-fraction`, which clamp to [0.05, 1.0]. Verify with ERT tests for the default value, the clamping and removing an entry.
- [x] 1.2 Change `neoment-media-image-size` to take a height FRACTION instead of the boolean ZOOM (design decision 4) and update its existing test. Verify `neoment-media-image-size` returns `(650 . 200)` for 0.2, `(650 . 1000)` for 1.0 and stays capped by the real size.

## 2. Focusable image line

- [x] 2.1 Rewrite `neoment-media--place-image` to insert `"\n" + padding + IMG` as read-only text after the header line, with the properties from design decision 1 (`neoment-message`, `neoment-decoration`, `neoment-image`, `keymap`, `neoment-image-file`, `help-echo`). Make `neoment-media-add-images` pass a marker instead of an integer and remove image text, not overlays, at the start of each pass (decision 2). Verify with an ERT test (stubbed `create-image`, cached file): the image line exists below the header, `neoment-room-message-at-point` on it returns the message, and copying the region with `neoment-room--filter-substring` leaves it out.
- [x] 2.2 Add an ERT test where two images arrive asynchronously in reverse order. Verify both land under their own headers, which proves the marker handling.
- [x] 2.3 Keep the terminal-frame test passing (no image text, `z` shows `No image on this line`). Verify with `make test`.

## 3. Stable point across re-renders

- [x] 3.1 Extend `neoment-room--position-anchor`/`neoment-room--anchor-position` to the `(KEY OFFSET IMAGE-P)` form, so OFFSET skips image text and IMAGE-P resolves to the image character (design decision 3). Keep the `(nil . LINE)` fallback. Verify with ERT tests: point in a body line survives a render where the image disappears, and point on an image survives a render where the image is still present.
- [x] 3.2 Move the `neoment-room-image-function` call in `neoment-room-render-buffer` to before the point and window-start restoration. Verify with an ERT test: with the image file cached and point on the image line, `neoment-room-render-buffer` leaves point on the image line (spec scenario "Sync while focused on an image").
- [x] 3.3 Run the existing room tests for "Stable re-render". Verify `make test` passes with no changes to those tests.

## 4. Image keymap: zoom and resize

- [x] 4.1 Add `neoment-media-image-map` (no parent) binding `z`, `+`, `-` and `o`. Add the in-place resize helper that rebuilds the `display` image from `neoment-image-file` without re-rendering (design decision 5). Verify with an ERT test that resizing keeps point and `buffer-modified-p` unchanged.
- [x] 4.2 Rework `neoment-room-toggle-image-zoom` to work from the image line or the header line: zoom when at the default size, otherwise reset to the default. Keep `No image on this line`. Verify with ERT tests for zoom in on the image, zoom from the header, and reset after `+`.
- [x] 4.3 Add `neoment-room-image-enlarge`/`neoment-room-image-shrink` (×/÷ 1.25, clamped), with the messages `Image is at its maximum size`/`Image is at its minimum size`. Verify with ERT tests: 0.2 → 0.25, the minimum limit message, and the size kept after `neoment-room-render-buffer`.
- [x] 4.4 Verify with an ERT test that `+` on a message text line does not resize any image (the keymap is only active on the image line).

## 5. Open image in image-mode

- [x] 5.1 Implement `neoment-room-image-open` (design decision 6). For `image` attachments, download via `neoment-media-download` with `neoment-media--attachment-file-name`, then show `*neoment-image: <filename>*` in `image-mode`, reusing an existing buffer. Delegate to `neoment-room-open-attachment` for video and location thumbnails, and show `Error fetching attachment: <reason>` on failure. Verify with ERT tests (stubbed download): the buffer name and `major-mode`, reuse of the same buffer, video delegation, and no buffer on error.

## 6. Docs and integration

- [x] 6.1 Update `README.md`: describe the focusable inline images and add the image keys (`z`, `+`, `-`, `o` on the image) to the key tables. Verify the tables match the bindings in `neoment-media-image-map`.
- [ ] 6.2 Manual check in a GUI Emacs against a real room: `C-n` onto an image, `z`/`+`/`-`/`o` work, `r` replies from the image line, a typing notification does not move the cursor off the image, and `emacs -nw` still shows only bubbles. Then verify `make test compile lint` passes.

## Workflow follow-up

- Archive the change after review with `/openspec-archive-change focusable-inline-images`, which syncs the `media-attachments` delta into the main spec.
