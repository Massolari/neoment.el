# Design

## Context

`neoment-room--body-text` returns a message body as markdown: `formatted_content` run through `neoment-markdown-from-html`, or the plain `content`. `neoment-room--message-lines` splits that body (and the replied message's body, prefixed with `┃ `) into lines, and each line goes through `neoment-room--style-line`, which only adds faces for quote lines, mentions and emoticons. The buffer copy filter (`neoment-room--filter-substring`) drops text marked `neoment-decoration`; everything else is copied as is. Re-rendering is a pure function of the model and restores the cursor by message and text offset.

## Goals / Non-Goals

**Goals:**
- One styling pass that works the same for HTML-derived and plain bodies.
- Markers hidden by an invisibility spec, not removed, so copy and cursor offsets see the full markdown.

**Non-Goals:**
- A CommonMark parser. The styling follows the same lightweight, regexp-based rules as the existing converter.
- Nested emphasis beyond what falls out of applying the rules in order (e.g. `***x***` may only get one face).

## Decisions

**Style the displayed markdown, not the HTML.** The faces are added by scanning the markdown string that is about to be displayed.
- Alternative: add text properties while converting HTML (`<strong>` → propertized `**x**`). It is more precise for formatted messages, but plain-body messages would still need a markdown scan, and the converter's chain of regexp replacements would have to preserve properties through every step. One scanner over the final text is simpler and covers both.

**Style the whole body, then split.** A new `neoment-room--style-body` takes the body string and returns it propertized; `neoment-room--message-lines` splits the result (`split-string` keeps text properties). Fenced code blocks span lines, so a per-line pass can't tell code lines from text. The replied message's body gets the same pass before its lines are prefixed with `┃ `. `neoment-room--style-line` keeps its current job (quotes, mentions, emoticons); the quote face is appended, so code and emphasis faces stay on top.

**Scan order and protected regions.** In the body pass:
1. Find fenced blocks (a line starting with ```` ``` ```` up to the next such line, or the end of the body). Fence lines get `neoment-markup`, inner lines `neoment-code`. These regions are protected.
2. In the rest, find inline code `` `x` `` (no newline inside): backticks are markers, content gets `neoment-code`. Protected.
3. Find links (`neoment-room--link-regexp`): the `(url)` part is protected so underscores and asterisks in URLs are never emphasis. Link text is still scanned.
4. Headings: `^#{1,3} ` lines; the prefix is a marker, the rest gets `neoment-heading`.
5. Emphasis, longest marker first: `**`/`__` (bold), `~~` (strike), then `*`/`_` (italic), on one line. The opening marker must be followed by a non-space and the closing one preceded by a non-space; `_` markers must not touch a word character on their outer side. A match that overlaps a protected region is skipped.

Faces are added with `add-face-text-property` so they combine (bold link text, italic mention, quote + code).

**Hide with `invisible`, keep in the text.** Markers get `invisible neoment-markup` and the face `neoment-markup`. The room mode adds `neoment-markup` to `buffer-invisibility-spec` when `neoment-room-hide-markup` is non-nil and removes it otherwise. `neoment-room-render-buffer` re-syncs the spec on each render, so changing the option takes effect on `g`. Because the markers stay in the text and are not decoration, the copy filter keeps them and cursor-offset restoration is unaffected.
- Alternative: delete the markers from the rendered string. Copy would lose the markdown, and showing markers again would need a different render path.
- Alternative: `display ""` instead of `invisible`. Works, but can't be toggled per buffer without re-rendering, and `invisible` is the usual Emacs mechanism.

**Faces live in `neoment-faces.el`.** `neoment-bold` (bold), `neoment-italic` (italic), `neoment-strike` (`:strike-through t`), `neoment-code` (`font-lock-constant-face`, matching the compose buffer), `neoment-heading` (bold), `neoment-markup` (shadow). Users can customize them like the existing faces.

**Strikethrough in the converter.** Add `<del>`, `<s>` and `<strike>` → `~~%1~~` to the inline rules in `neoment-markdown-from-html`, before the catch-all tag rule.

## Risks / Trade-offs

- [Literal asterisks the sender escaped (HTML `a *b* c`) are displayed as italic] → Accepted: the converter already loses escaping, and the "must not be followed by a space" rule keeps arithmetic like `2 * 3` plain.
- [Plain-text bodies from clients without markdown get styled] → Accepted: the room buffer already treats bodies as markdown; the rules are conservative.
- [Cursor motion over invisible markers can land "inside" a hidden marker] → Emacs skips invisible text on command loop point adjustment; no special handling needed.
- [Scanning every body on every render costs time] → The passes are linear regexp scans over short strings; rendering already runs several per line.

## Migration Plan

None. The new option defaults to hiding markers; setting `neoment-room-hide-markup` to nil restores visible markers (now dimmed and styled).
