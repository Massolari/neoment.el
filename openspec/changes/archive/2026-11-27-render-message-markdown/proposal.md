# Proposal

## Why

Message bodies in the room buffer are converted from Matrix HTML to markdown, but the markdown is shown as raw text: `**this**` appears with its asterisks instead of in bold, mentions show as `[Alice](https://matrix.to/#/@alice:s)`, and code blocks are plain. Only quotes, mentions and emoticons get a face today. The Neovim client gets readable messages by parsing the room buffer as markdown with treesitter and concealing the markup (`conceallevel=2`). The Emacs port lost that because Emacs has no equivalent built in.

## What Changes

Reproduce the Neovim display, adapted to Emacs, in room and thread buffers (message bodies and reply quotes):

- `**x**` / `__x__` in bold, `*x*` / `_x_` in italic, `~~x~~` struck through, `` `x` `` in a code face, with no emphasis inside code.
- Fenced code blocks: inner lines highlighted with the major mode for the fence's language (e.g. ```` ```elisp ```` → `emacs-lisp-mode`), falling back to a code face. This matches Neovim's language injection.
- `#`, `##`, `###` lines in a heading face, with the `#` marker kept visible (as in Neovim).
- Links `[text](url)`, including mentions, emoticons and spoilers, show only `text`. The brackets and `(url)` are hidden, so a mention reads `Alice`, an emoticon `img: :party:`, and a spoiler `Spoiler`.
- Hidden markup: emphasis markers, inline-code backticks, fence backticks (the language name stays) and link brackets/URLs are invisible by default. A new option `neoment-room-hide-markup` (default `t`) shows them, dimmed. This plays the role of Neovim's `conceallevel`.
- Copying keeps the full markdown (markers and URLs), the same as yanking a concealed line in Neovim.
- Because URLs are hidden, link text shows the URL in its tooltip, and `o` (or mouse-1) on a link opens it with `browse-url`. On a spoiler it shows the spoiler content in the echo area. This replaces Neovim's `gx`.
- New faces: `neoment-bold`, `neoment-italic`, `neoment-strike`, `neoment-code`, `neoment-heading`, `neoment-markup`, `neoment-link`.
- The HTML-to-markdown converter turns `<del>`, `<s>` and `<strike>` into `~~x~~` instead of dropping the tag. The Neovim converter drops it too, so this is an Emacs-only improvement.

Out of scope: sending `~~` as `<del>`, list-bullet decoration, backslash-escape concealment, and styling the room-list last-message preview or notifications.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `room-timeline`: new requirements for markdown styling of message bodies (emphasis, code, headings, links), for hiding markup, and for copy keeping markdown.
- `media-attachments`: `o` opens the link (or reveals the spoiler) at point before falling back to emoticon/attachment handling.
- `markdown-conversion`: strikethrough tags (`<del>`, `<s>`, `<strike>`) become `~~` when displaying.

## Impact

- `neoment-room.el`: body styling pass over the whole body before line splitting, code-block fontification with a cache, invisibility spec in mode setup, new defcustom.
- `neoment-media.el`: `neoment-room-open-attachment` checks for a link at point first.
- `neoment-faces.el`: new faces.
- `neoment-markdown.el`: strikethrough rule in `neoment-markdown-from-html`.
- `README.md`: option and `o` behaviour.
- Tests in `test/neoment-room-test.el`, `test/neoment-media-test.el` and `test/neoment-markdown-test.el`.
- No API, dependency or storage changes. Language modes are used only if they are already available.
