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
In GUI frames, image attachments (or thumbnails) SHALL render below the message header, starting at column 31. Maximum width is `window width - 31 - 4` and maximum height is 20% of window height, both capped by the real image size. If the buffer re-renders before the download finishes, the image SHALL be dropped. In terminal frames only the bubble shows.

#### Scenario: Terminal frame
- **WHEN** an image message is shown in `emacs -nw`
- **THEN** only the `󰋩  Image: <file>` bubble is displayed

### Requirement: Image zoom
`z` SHALL toggle the image on the current line between 20% and 100% of window height. Without an image it shows `No image on this line`.

#### Scenario: Zoom in
- **WHEN** the user presses `z` on an inline image
- **THEN** the image is re-displayed with max height equal to the window height

### Requirement: Open attachment
`o` on an `mxc://` emoticon or reaction SHALL download it as `<sanitised title>.png` and call the handler with origin `emoticon`/`reaction`. Otherwise it uses the message attachment, downloads it to `<event_id><filename>` in the media directory (showing `Fetching attachment <f>...` and `Opening attachment <f>...`), and calls `neoment-on-open-attachment-function` with the path and the attachment, origin `message`. Locations pass the map URL.

#### Scenario: No attachment
- **WHEN** the message has no attachment
- **THEN** `No attachment on this message` is shown

#### Scenario: Location without URL
- **WHEN** a location attachment has no URL
- **THEN** `No URL for this location attachment` is shown

### Requirement: Default open handler
By default, audio files SHALL play with `mpv` in a small 3-line window below when `mpv` is available. Everything else SHALL open with the system program.

#### Scenario: Audio with mpv installed
- **WHEN** the user opens an audio attachment and `mpv` is on PATH
- **THEN** a 3-line window runs `mpv <file>`

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
