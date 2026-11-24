# Spec Delta

## ADDED Requirements

### Requirement: Inline emphasis in message bodies
In message bodies and reply quotes, `**x**` and `__x__` SHALL use `neoment-bold`, `*x*` and `_x_` SHALL use `neoment-italic`, and `~~x~~` SHALL use `neoment-strike`. A marker counts only when the text it opens is not whitespace and an `_` or `__` marker is not inside a word. Emphasis MUST NOT apply inside inline code, code blocks, or the URL part of a `[text](url)` link.

#### Scenario: Bold text
- **WHEN** Alice sends a message whose body is `say **this** now`
- **THEN** `this` has the face `neoment-bold` and `say ` and ` now` do not

#### Scenario: Italic forwarded notice
- **WHEN** a forwarded message is displayed
- **THEN** `↪️ Forwarded:` has the face `neoment-italic`

#### Scenario: Underscores inside a word
- **WHEN** the body is `snake_case_name`
- **THEN** no part of it has the face `neoment-italic`

#### Scenario: Lone asterisk
- **WHEN** the body is `2 * 3 * 4`
- **THEN** no part of it has the face `neoment-italic`

#### Scenario: Strikethrough
- **WHEN** the body is `~~old~~ new`
- **THEN** `old` has the face `neoment-strike`

### Requirement: Inline code in message bodies
Inline `` `x` `` SHALL use `neoment-code`, with no other markdown styling inside it.

#### Scenario: Inline code keeps asterisks
- **WHEN** the body is `` run `a**b**c` ``
- **THEN** `a**b**c` has the face `neoment-code` and none of it has the face `neoment-bold`

### Requirement: Code blocks in message bodies
Lines between an opening ```` ```[lang] ```` line and the next ```` ``` ```` line (or the end of the body) SHALL be highlighted like the major mode for `lang` when that mode is available, and SHALL use `neoment-code` otherwise. No markdown styling SHALL apply inside them. The language name on the opening fence SHALL use `neoment-markup`.

#### Scenario: Known language
- **WHEN** the body is ```` ```elisp ````, `(defun f () "doc")`, ```` ``` ```` on three lines
- **THEN** `defun` has the keyword face `emacs-lisp-mode` gives it and `"doc"` has a string face

#### Scenario: Unknown or missing language
- **WHEN** the body is ```` ``` ````, `a *b* c`, ```` ``` ```` on three lines
- **THEN** `a *b* c` has the face `neoment-code` and no part of it is italic

### Requirement: Headings in message bodies
A body line starting with `# `, `## ` or `### ` SHALL use `neoment-heading` for the whole line, marker included. The marker is never hidden.

#### Scenario: Second-level heading
- **WHEN** the body is `## Notes`
- **THEN** the line shows `## Notes` with the face `neoment-heading`

### Requirement: Links in message bodies
For a `[text](url)` link outside code, `text` SHALL be the visible part, `url` SHALL be shown as its tooltip, and `text` SHALL use `neoment-link` unless a mention or emoticon face applies. A spoiler `[Spoiler…](content)` SHALL show only `Spoiler…`, with no tooltip.

#### Scenario: Mention shows the name
- **WHEN** a message mentions `[Alice](https://matrix.to/#/@alice:s)` with the default settings
- **THEN** the buffer shows `Alice` in `neoment-mention` and no part of the URL is visible

#### Scenario: Mention with underscores
- **WHEN** the body is `[Foo](https://matrix.to/#/@foo_bar_baz:s)`
- **THEN** no part of the URL has the face `neoment-italic`

#### Scenario: Spoiler hidden
- **WHEN** the body is `[Spoiler](<the end>)` with the default settings
- **THEN** the buffer shows `Spoiler` and `the end` is not visible

#### Scenario: Plain link
- **WHEN** the body is `see [docs](https://example.org)`
- **THEN** the buffer shows `see docs`, `docs` in `neoment-link`, with the tooltip `https://example.org`

### Requirement: Hidden markup characters
When `neoment-room-hide-markup` is non-nil (the default), these SHALL be invisible in room and thread buffers: emphasis markers, inline-code backticks, fence backticks, and a link's `[`, `]` and `(url)`. When it is nil, they SHALL be visible in `neoment-markup`. Re-rendering the buffer (`g`) SHALL apply a changed value.

#### Scenario: Default display
- **WHEN** Alice sends `**this**` at 09:12:44 with the default settings
- **THEN** the line reads `09:12:44               Alice │ this` with `this` in bold

#### Scenario: Markup shown
- **WHEN** `neoment-room-hide-markup` is nil and the body is `**this**`
- **THEN** the line shows `**this**`, the asterisks in `neoment-markup` and `this` in bold

#### Scenario: Code fence display
- **WHEN** a code block opens with ```` ```elisp ```` with the default settings
- **THEN** the opening fence line shows only `elisp` and the closing fence line shows no text after the gutter

### Requirement: Copy keeps markdown
Copying styled message text MUST include all markdown, hidden or not, so the copied text is the message's markdown.

#### Scenario: Copy a bold message
- **WHEN** the user copies the line showing a bold `this` sent as `**this**`
- **THEN** the kill ring receives `**this**`

#### Scenario: Copy a mention
- **WHEN** the user copies a line showing the mention `Alice`
- **THEN** the kill ring receives `[Alice](https://matrix.to/#/@alice:s)`
