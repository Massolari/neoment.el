# Design

## Context

`neoment-room--body-text` returns a message body as markdown: `formatted_content` run through `neoment-markdown-from-html` (a port of `neoment.nvim/lua/neoment/markdown.lua`), or the plain `content`. `neoment-room--message-lines` splits that body (and the replied body, prefixed with `┃ `) into lines, and `neoment-room--style-line` adds faces only for quote lines, mentions and emoticons. The copy filter (`neoment-room--filter-substring`) drops `neoment-decoration` text and copies everything else. Re-rendering is a pure function of the model and restores the cursor by message and text offset.

**Neovim reference.** In `neoment.nvim`, `after/ftplugin/neoment_room.lua` runs `vim.treesitter.start(buf, "markdown")` on the room buffer, and the window sets `conceallevel=2` and `concealcursor=n`. The styling therefore comes from Neovim's default `markdown`/`markdown_inline` highlight queries:

| Neovim (treesitter + conceal) | Emacs adaptation |
| --- | --- |
| emphasis, strong, strikethrough highlighted; delimiters concealed | faces + `invisible` markers |
| code span highlighted; backticks concealed | `neoment-code` + `invisible` backticks |
| fenced block: language injected; fence backticks concealed, info string kept | fontify with the language's major mode; backticks invisible, language kept |
| ATX heading highlighted; `#` marker visible | `neoment-heading` on the whole line |
| inline link: brackets and destination concealed | `[`, `](url)` invisible; URL in `help-echo` |
| `gx` opens the link under the cursor | `o` / mouse-1 open the link |
| conceal is display-only, yank keeps markdown | markers stay in the text, not decoration |
| `conceallevel` user option | `neoment-room-hide-markup` |

Two differences in the Neovim setup are deliberately not copied. Treesitter parses the whole buffer, gutter included, so emphasis could in theory span gutter text. And treesitter markdown follows CommonMark, which the regexp rules here approximate.

## Goals / Non-Goals

**Goals:**
- Match the Neovim reading experience: same visible text, same things hidden.
- One styling pass that works the same for HTML-derived and plain bodies.
- Markers hidden through an invisibility spec, not removed, so copy and cursor offsets see the full markdown.

**Non-Goals:**
- A CommonMark parser, or a dependency on `markdown-mode` or a tree-sitter grammar.
- Nested emphasis beyond what falls out of applying the rules in order (`***x***` may get only one face).

## Decisions

**Style the displayed markdown, not the HTML.** Faces are added by scanning the markdown string about to be displayed, as treesitter does in Neovim.
- Alternative: propertize while converting HTML. That is more precise for formatted messages, but plain bodies still need a scan, and every regexp step of the converter would have to preserve properties.
- Alternative: use `markdown-mode` or the `markdown` tree-sitter grammar on the room buffer. That is the closest to Neovim, but it adds a dependency (or a grammar install). Those modes also font-lock the whole buffer, gutter included, and would fight the renderer's own `face` properties.

**Style the whole body, then split.** A new `neoment-room--style-body` takes a body string and returns it propertized. `neoment-room--message-lines` splits the result (`split-string` keeps properties). Fenced blocks span lines, so a per-line pass can't tell code from text. The replied body gets the same pass before its lines are prefixed with `┃ `. `neoment-room--style-line` keeps the quote face (appended, so code and emphasis faces stay on top). Its mention and emoticon faces move into the link step below, so link handling lives in one place.

**Scan order and protected regions.** In the body pass:
1. **Fenced blocks:** from a line starting with ```` ``` ```` to the next such line, or the end of the body. The backticks are markers. The language name gets `neoment-markup`. Inner lines are fontified (next decision). The region is protected.
2. **Inline code** `` `x` `` (no newline inside): the backticks are markers and the content gets `neoment-code`. Protected.
3. **Links** (`neoment-room--link-regexp`, extended to accept `(<…>)` destinations as spoilers produce them): `[` and `](url)` are markers, protected. The text gets `neoment-link`, or `neoment-mention`/`neoment-mention-user` for `matrix.to` user URLs, or `neoment-emoticon` (plus the existing `neoment-emoticon` property) for `img:` + `mxc://`. The text also gets `neoment-link` = URL, `help-echo` = URL (none for spoilers), `mouse-face highlight`, and a small `keymap` binding `mouse-1` to the open command. Link text is still scanned for emphasis.
4. **Headings:** `^#{1,3} ` lines get `neoment-heading` over the whole line. Nothing is hidden.
5. **Emphasis**, longest marker first, on one line: `**`/`__` (bold), `~~` (strike), then `*`/`_` (italic). The opening marker must be followed by a non-space and the closing one preceded by a non-space. `_` markers must not touch a word character on their outer side. A match overlapping a protected region is skipped.

Faces are added with `add-face-text-property` so they combine (bold link text, quote + code).

**Code block fontification.** The language name maps to a mode: `<lang>-mode`, with a small alias table (`elisp`/`emacs-lisp` → `emacs-lisp-mode`, `js`/`javascript` → `js-mode`, `ts` → `typescript-ts-mode` if present, `sh`/`bash`/`shell` → `sh-mode`, `py` → `python-mode`, and so on). When the mode is `fboundp`, the code goes into a reused hidden buffer, the mode is enabled with hooks suppressed (`delay-mode-hooks`), `font-lock-ensure` runs, and the `face` and `font-lock-face` properties are copied onto the body text as `face`. Results are cached in a hash table keyed by `(mode . code)` with a size cap, since renders are frequent and code rarely changes. Any error, an unknown language or no language falls back to `neoment-code`. This mirrors Neovim's injection without requiring every grammar.

**Hide with `invisible`, keep in the text.** Markers get `invisible neoment-markup` and the face `neoment-markup`. The room mode adds `neoment-markup` to `buffer-invisibility-spec` when `neoment-room-hide-markup` is non-nil and removes it otherwise. `neoment-room-render-buffer` re-syncs it on each render, so `g` applies a changed option. The markers stay in the text and are not decoration, so the copy filter keeps them and cursor-offset restoration is unaffected. A fence line whose backticks are hidden becomes the language name or an empty-looking line, like a concealed fence in Neovim.
- Alternative: delete the markers from the rendered string. Copy would lose the markdown, and showing them again would need another render path.
- Alternative: `display ""`. It can't be toggled through the invisibility spec, and `invisible` is the usual mechanism.

**Opening links.** `neoment-room-open-attachment` (`o`) first looks for a `neoment-link` property at point. A spoiler (link text starting with `Spoiler`, and the URL being its content) is shown with `neoment-notify--message`. Any other non-`mxc://` URL goes to `browse-url`. Otherwise the existing emoticon/reaction/attachment logic runs unchanged. mouse-1 on link text calls the same command at the click position. RET keeps its compose binding; the link keymap binds only mouse-1, so keyboard behaviour on links doesn't change.

**Faces in `neoment-faces.el`.** `neoment-bold` (bold), `neoment-italic` (italic), `neoment-strike` (`:strike-through t`), `neoment-code` (`font-lock-constant-face`, like the compose buffer), `neoment-heading` (bold `font-lock-function-name-face`, close to Neovim's `@markup.heading`), `neoment-markup` (shadow), `neoment-link` (link).

**Strikethrough in the converter.** Add `<del>`, `<s>` and `<strike>` → `~~%1~~` to the inline rules in `neoment-markdown-from-html`, before the catch-all tag rule.

## Risks / Trade-offs

- [Literal asterisks the sender escaped (HTML `a *b* c`) display as italic] → Accepted. Neovim has the same behaviour, since the converter drops escaping, and the "not followed by a space" rule keeps `2 * 3` plain.
- [Hidden URLs hide where a link points] → The tooltip shows the URL, and `o`/mouse-1 open it. Setting `neoment-room-hide-markup` to nil shows everything.
- [Enabling arbitrary major modes to fontify code can be slow or error] → Hooks are delayed, errors fall back to `neoment-code`, and results are cached. Only modes already defined are used; nothing is autoloaded from packages that aren't installed.
- [Cursor motion over invisible text] → Emacs adjusts point out of invisible text after commands; `n`/`p` and line anchors work on message properties, not columns.
- [Scanning every body on every render] → Linear regexp scans over short strings. Code fontification is the only expensive step, and it is cached.

## Migration Plan

None. Markup is hidden by default. Setting `neoment-room-hide-markup` to nil shows markers and URLs, dimmed.
