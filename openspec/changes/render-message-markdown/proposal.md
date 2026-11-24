# Proposal

## Why

Message bodies in the room buffer are converted from Matrix HTML to markdown, but the markdown is shown as raw text: `**this**` appears with its asterisks instead of in bold, and the same goes for italics, inline code, code blocks and headings. Only quotes, mentions and emoticons get a face today, so formatted messages are harder to read than in any other Matrix client.

## What Changes

- Style markdown in message bodies (and in reply quotes) in the room and thread buffers:
  - `**x**` / `__x__` in bold, `*x*` / `_x_` in italic, `~~x~~` struck through
  - `` `x` `` and the lines of fenced ```` ``` ```` blocks in a code face, with no emphasis styling inside code
  - `#`, `##`, `###` lines in a heading face
- Hide the markup characters (`**`, `*`, `_`, `__`, `~~`, backticks, `# `) by default, so `**this**` reads as a bold `this`. Fence lines stay visible in a dimmed face. A new option `neoment-room-hide-markup` (default `t`) shows the markers instead, still dimmed.
- Copying message text keeps the markdown markers, so a copied message pastes back into the compose buffer with the same formatting.
- New faces: `neoment-bold`, `neoment-italic`, `neoment-strike`, `neoment-code`, `neoment-heading`, `neoment-markup`.
- The HTML-to-markdown converter turns `<del>`, `<s>` and `<strike>` into `~~x~~` instead of dropping the tag.

Out of scope: making links clickable or hiding link URLs (there is no "open link" command yet), syntax highlighting inside code blocks, sending `~~` as `<del>`, and styling the room-list last-message preview or notifications.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `room-timeline`: new requirements for markdown styling of message bodies and for hiding markup characters.
- `markdown-conversion`: strikethrough tags (`<del>`, `<s>`, `<strike>`) become `~~` when displaying.

## Impact

- `neoment-room.el`: body lines are styled as a whole body (code fences span lines) before being split into lines; mode setup adds the markup symbol to `buffer-invisibility-spec`; new defcustom.
- `neoment-faces.el`: new faces.
- `neoment-markdown.el`: strikethrough rule in `neoment-markdown-from-html`.
- Tests in `test/neoment-room-test.el` and `test/neoment-markdown-test.el`.
- No API, dependency or storage changes.
