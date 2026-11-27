# media-attachments Specification

## Purpose

Handles media safely and conveniently: authenticated downloads that never leak the access token, inline images with zoom in GUI frames, opening and saving attachments, uploading files and clipboard images.

## Requirements

### Requirement: Authenticated media download
Media SHALL be downloaded from `<hs>/_matrix/client/v1/media/download/<server>/<id>` with the `Authorization` header and stored under `<cache>/neoment/media/`. Images for display SHALL be cached by `mxc://` URL.

#### Scenario: Same image twice
- **WHEN** two messages reference the same `mxc://` image
- **THEN** it is downloaded once

### Requirement: Only mxc URLs fetched for embedded media
Emoticons, custom reactions and avatars SHALL be fetched only when their URL is `mxc://`. Other URLs MUST NOT be requested.

#### Scenario: Emoticon with https src
- **WHEN** an emoticon has `src="https://evil.example/x.png"`
- **THEN** no request is made and it is not styled as an emoticon

### Requirement: Inline images
In GUI frames, image attachments (or thumbnails) SHALL render on their own line directly below the message header, starting at column 31. Maximum width is `window width - 31 - 4` and the default maximum height is 20% of window height, both capped by the real image size. If the buffer re-renders before the download finishes, the image SHALL be dropped. In terminal frames only the bubble shows.

#### Scenario: Terminal frame
- **WHEN** an image message is shown in `emacs -nw`
- **THEN** only the `󰋩  Image: <file>` bubble is displayed

### Requirement: Image zoom
`z` SHALL toggle an image between its default size (20% of window height) and zoomed (100% of window height). It SHALL work with the cursor on the image line or on its message header line. Elsewhere it shows `No image on this line`. If the image was resized with `+`/`-`, `z` SHALL return it to the default size.

#### Scenario: Zoom in
- **WHEN** the user presses `z` with the cursor on an inline image at its default size
- **THEN** the image is re-displayed with max height equal to the window height and the cursor stays on it

#### Scenario: Zoom from the header line
- **WHEN** the user presses `z` on the header line of a message with an inline image
- **THEN** that image toggles zoom

#### Scenario: Zoom out after resizing
- **WHEN** the user has pressed `+` on an image and then presses `z` on it
- **THEN** the image returns to the default 20% height

### Requirement: Open attachment
`o` (or mouse-1) on a spoiler link SHALL show its content in the echo area, and on any other non-`mxc://` link SHALL open the URL with `browse-url`. Otherwise, `o` on an `mxc://` emoticon or reaction SHALL download it as `<sanitised title>.png` and call the handler with origin `emoticon`/`reaction`. Otherwise it uses the message attachment, downloads it to `<event_id><filename>` in the media directory (showing `Fetching attachment <f>...` and `Opening attachment <f>...`), and calls `neoment-on-open-attachment-function` with the path and the attachment, origin `message`. Locations pass the map URL.

#### Scenario: No attachment
- **WHEN** the message has no attachment
- **THEN** `No attachment on this message` is shown

#### Scenario: Location without URL
- **WHEN** a location attachment has no URL
- **THEN** `No URL for this location attachment` is shown

#### Scenario: Open a link
- **WHEN** the cursor is on the visible text `docs` of `[docs](https://example.org)` and the user presses `o`
- **THEN** `https://example.org` is opened with `browse-url` and no attachment is fetched

#### Scenario: Reveal a spoiler
- **WHEN** the cursor is on `Spoiler` of `[Spoiler](<the end>)` and the user presses `o`
- **THEN** the echo area shows `the end`

### Requirement: Default open handler
By default, audio files SHALL play in the controlled audio player (see `audio-player`) when `mpv` is available and supported on the platform, and the player window SHALL be shown. Everything else SHALL open with the system program.

#### Scenario: Audio with mpv installed
- **WHEN** the user opens an audio attachment and `mpv` is on PATH
- **THEN** the audio player starts and its state window is shown

#### Scenario: Non-audio file
- **WHEN** the user opens a PDF attachment
- **THEN** it opens with the system program

### Requirement: Save attachment
`s` SHALL prompt `Save attachment to: `. An empty answer shows `Save location not provided`. A directory gets the filename appended. If the file exists, the client asks `File exists. Overwrite?`. Answering No picks the first free `name(1).ext`, `name(2).ext`, and so on. It then writes the file and shows `Attachment saved to <path>`.

#### Scenario: Avoid overwrite
- **WHEN** `a.png` and `a(1).png` exist and the user declines to overwrite
- **THEN** the file is saved as `a(2).png`

### Requirement: Upload file
`u` SHALL prompt `Enter file path: `. A missing file shows `File does not exist: <p>`. Otherwise it SHALL `POST /_matrix/media/v3/upload?filename=<name>` with the file bytes and its detected mimetype, and open compose with attachment `{filename, url: content_uri, mimetype, size}`.

#### Scenario: Successful upload
- **WHEN** the user uploads an existing `report.pdf`
- **THEN** compose opens titled `... with the attachment report.pdf`

### Requirement: Clipboard image upload
`U` SHALL save the clipboard image to a temporary PNG, upload it and open compose with it. It tries the GUI selection first, then a platform tool: `osascript` or `pngpaste` on macOS, `xclip` or `wl-paste` on Linux, PowerShell on Windows. Errors: `No image found in clipboard`, `Clipboard image upload not supported on this platform`, `Failed to save clipboard image to temporary file`, and the xclip install hint.

#### Scenario: Clipboard has text only
- **WHEN** the clipboard contains no image
- **THEN** `No image found in clipboard` is shown

### Requirement: Focusable image line
The inline image line SHALL be buffer text the cursor can move onto. It SHALL belong to its message, so message actions work from it, and it SHALL be a decoration left out of copied text.

#### Scenario: Cursor moves onto the image
- **WHEN** the cursor is on the header line of a message with an inline image and the user presses `C-n`
- **THEN** the cursor rests on the image line

#### Scenario: Message actions from the image
- **WHEN** the cursor is on an image line and the user presses `r`
- **THEN** a reply to that image's message starts

#### Scenario: Copy leaves out the image
- **WHEN** the user copies a region that spans a message with an inline image
- **THEN** the copied text contains the message text but nothing from the image line

### Requirement: Image resize
With the cursor on an inline image, `+` SHALL multiply that image's maximum height by 1.25 and `-` SHALL divide it by 1.25. The result is clamped to 5%–100% of window height and stays capped by the window width and the real image size. At either limit it shows `Image is at its maximum size` or `Image is at its minimum size`.

#### Scenario: Enlarge
- **WHEN** the user presses `+` on an image at the default 20% height
- **THEN** the image is re-displayed with max height of 25% of window height

#### Scenario: Shrink at the limit
- **WHEN** the image's max height is already 5% of window height and the user presses `-`
- **THEN** the size is unchanged and `Image is at its minimum size` is shown

#### Scenario: Keys outside an image
- **WHEN** the cursor is on a message text line and the user presses `+`
- **THEN** no image changes size

### Requirement: Open image in image-mode
With the cursor on an inline image of an `image` attachment, `o` SHALL show the full-resolution attachment in its own buffer in `image-mode`, named `*neoment-image: <filename>*`. The buffer already showing that attachment SHALL be reused; a different attachment with the same filename SHALL get a buffer of its own (with a uniquified name). For video or location thumbnails, `o` SHALL behave as on any other line of the message.

#### Scenario: Open an image
- **WHEN** the user presses `o` on an inline image of `cat.png`
- **THEN** a buffer `*neoment-image: cat.png*` in `image-mode` shows the image

#### Scenario: Two images with the same filename
- **WHEN** the user presses `o` on an image `image.png`, then on another message's image also named `image.png`
- **THEN** each image is shown in its own buffer, and pressing `o` again on the first one reuses its buffer

#### Scenario: Open a video thumbnail
- **WHEN** the user presses `o` on the thumbnail of a video message
- **THEN** the video is opened with `neoment-on-open-attachment-function`

#### Scenario: Download failure
- **WHEN** fetching the attachment fails
- **THEN** `Error fetching attachment: <reason>` is shown and no buffer is created

### Requirement: Image focus and size survive re-render
When the room buffer re-renders, the cursor and window starts on an image line SHALL return to the same image once it is placed. Each image's size (default, zoomed or resized) SHALL be kept per message for as long as the buffer lives.

#### Scenario: Sync while focused on an image
- **WHEN** the cursor is on an already downloaded inline image and a new message arrives
- **THEN** after the re-render the cursor is still on that image

#### Scenario: Size kept across re-render
- **WHEN** the user enlarged an image with `+` and the buffer re-renders
- **THEN** the image keeps its enlarged size
