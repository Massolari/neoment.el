# Design

## Context

Today `neoment-media-add-images` runs at the end of `neoment-room-render-buffer`, after point and window starts have been restored. For every message header it calls `neoment-media-image-file`. That function calls back synchronously when the file is already cached and asynchronously after a download. `neoment-media--place-image` then adds a zero-width overlay whose `after-string` is `"\n" + 31 spaces + image`. Because overlays take no buffer positions:

- point cannot rest on the image;
- positions captured before an async callback stay valid (nothing shifts);
- `neoment-room--position-anchor` (message key + character offset) never has to account for images.

Moving the image into the buffer text breaks the last two assumptions, so the design centres on them. The minimum Emacs version is 29.1.

## Goals / Non-Goals

**Goals:**
- Image lines are real, read-only text that point can visit and that carries its own keymap.
- Point and window starts stay stable across re-renders, whether or not images are present.
- Resizing does not re-render the whole buffer.

**Non-Goals:**
- Mouse bindings on the image (clicking to open or zoom). They are easy to add later through the same keymap.
- Showing animated GIFs as animations, or zoom/size state that persists across Emacs sessions.
- Changing avatars in `neoment-room-info`, which keep their own `o`/`z`.
- Terminal frames: they still get no images.

## Decisions

### 1. Image line as propertized text inserted after the header line

At placement time we insert `"\n" + padding + IMG`, where `IMG` is one space with a `display` image property. It goes at the end of the header line, with `inhibit-read-only` bound. Text properties:

- whole string: `neoment-message KEY` (so `neoment-room-message-at-point` and every message action work from the image line), `neoment-decoration t` (copy filter drops it), `neoment-image KEY`;
- padding + `IMG`: `keymap neoment-media-image-map`, so the image keys apply anywhere on the line, including the padding where `C-n` often lands because of the goal column;
- `IMG`: `neoment-image-file FILE` (the cached path, reused for resizing) and `help-echo` listing the keys.

*Alternative: keep the overlay and add a `cursor-sensor`/invisible placeholder.* It is more fragile and still gives point no real position. ement.el's approach (text with `display`) is the idiomatic one.

### 2. Placement uses markers

Async callbacks receive a marker on the header line, not an integer, because earlier insertions now shift later positions. The marker is released once the image is placed or dropped. The render tick check that drops late images stays.

### 3. Images are placed before point is restored, and anchors ignore image text

`neoment-room-render-buffer` will call `neoment-room-image-function` right after inserting the rendered text, *before* it restores the point and window anchors. Cached images (the common case after the first view) are then present when anchors resolve.

Anchors also stop counting image text:

- `neoment-room--position-anchor` returns `(KEY OFFSET IMAGE-P)`. OFFSET counts only characters of the message that do not carry `neoment-image`. IMAGE-P is non-nil when pos is on an image line.
- `neoment-room--anchor-position` resolves IMAGE-P to the `IMG` character of KEY's image when there is one. Otherwise it walks OFFSET over non-image characters.

This keeps anchors correct when an image is missing on one side of the render: hidden buffer, download still in flight, or a terminal frame. Before this change, a 33-character mismatch would have pushed point into the wrong body line. The `(nil . LINE)` fallback is unchanged.

*Alternative: re-render then move point to the image once it arrives.* That needs pending-focus bookkeeping and makes the cursor jump visibly. It is rejected for the first-view case: if the image isn't cached yet, point lands on the header and stays there.

### 4. Per-message height fraction replaces the zoom list

`neoment-room--zoomed` (list of keys) becomes `neoment-room--image-heights`, a buffer-local alist from KEY to a fraction of window height. A missing entry means the default of 0.2. `neoment-media-image-size` takes that fraction instead of the boolean ZOOM. Callers and the existing test change accordingly.

- `z`: if the fraction differs from the default, remove the entry; otherwise set it to 1.0.
- `+`/`-`: multiply or divide by 1.25, then clamp to [0.05, 1.0]. When clamping leaves the value unchanged, show the limit message.

### 5. Resizing swaps the display property in place

`z`, `+` and `-` with point on an image line call `create-image` on the stored `neoment-image-file` with the new size, then `put-text-property` the new `display` on `IMG`. There is no re-render, so point, window start and other images are untouched. `z` from the header line uses the same path by finding the image line of the header's key. If no image text exists (terminal, or not downloaded yet), it shows `No image on this line`, as today.

The command stays `neoment-room-toggle-image-zoom`, still bound to `z` in `neoment-room-mode-map`, so header-line zoom and user rebinds keep working. `neoment-media-image-map` binds `z` to the same command, plus `+` → `neoment-room-image-enlarge`, `-` → `neoment-room-image-shrink` and `o` → `neoment-room-image-open`. It has no parent, so every other key falls through to the room map.

### 6. `o` opens the full attachment in a non-file `image-mode` buffer

`neoment-room-image-open` applies only when the message's attachment type is `image`. Otherwise it delegates to `neoment-room-open-attachment`, which covers video and location thumbnails. It downloads the full attachment with `neoment-media-download` under the same name `o` already uses (`neoment-media--attachment-file-name`), so the cache is shared. Then it:

- reuses the buffer whose buffer-local `neoment-media--image-buffer-path` is the downloaded path, or else creates a new buffer with `generate-new-buffer` named `*neoment-image: <filename>*`, so clients that send generic names such as `image.png` do not make two images share one buffer;
- if the buffer is new, records the path and inserts the file with `insert-file-contents-literally` into a unibyte buffer, sets `default-directory` to the media directory and turns on `image-mode`;
- `pop-to-buffer`s it.

*Alternative: `find-file` the cached path.* The buffer would be named after the internal `<event_id><filename>`, and editing or killing it would touch the cache file. A non-file buffer still supports `image-mode`'s zoom/rotate and `image-save`.

This bypasses `neoment-on-open-attachment-function` on purpose: plain `o` on any other line still calls it.

## Risks / Trade-offs

- [Tall images make line-based scrolling jumpy, a known Emacs limitation with large inline images] → The default stays at 20% of the height. `pixel-scroll-precision-mode` helps users who zoom.
- [Re-renders while the first download is in flight leave point on the header, not the image] → Accepted. The spec only promises focus for placed images, and after one download every later render is synchronous.
- [Inserting text shifts positions other code may hold] → Room code reads positions from text properties after render and holds no integer positions across renders. Placement uses markers (decision 2).
- [`+` needs Shift on most layouts] → Accepted for now; an `=` alias is a one-line follow-up if wanted.

## Migration Plan

No data or config migration. `neoment-room--zoomed` is internal buffer-local state and is simply replaced. Rollback is a plain revert.
