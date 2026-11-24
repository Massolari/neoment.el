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

#### Scenario: Mention with underscores
- **WHEN** the body is a mention link `[Foo](https://matrix.to/#/@foo_bar_baz:s)`
- **THEN** the link keeps its mention face and no part of the URL is italic

#### Scenario: Lone asterisk
- **WHEN** the body is `2 * 3 * 4`
- **THEN** no part of it has the face `neoment-italic`

#### Scenario: Strikethrough
- **WHEN** the body is `~~old~~ new`
- **THEN** `old` has the face `neoment-strike`

### Requirement: Code in message bodies
Inline `` `x` `` SHALL use `neoment-code`. Lines between an opening ```` ```[lang] ```` line and the next ```` ``` ```` line SHALL use `neoment-code`, with no other markdown styling inside them. The fence lines themselves SHALL stay visible in `neoment-markup`.

#### Scenario: Inline code keeps asterisks
- **WHEN** the body is `` run `a**b**c` ``
- **THEN** `a**b**c` has the face `neoment-code` and none of it has the face `neoment-bold`

#### Scenario: Code block
- **WHEN** the body is ```` ```elisp ````, `(+ 1 *x*)`, ```` ``` ```` on three lines
- **THEN** the middle line has the face `neoment-code` and no italic, and both fence lines are visible in the face `neoment-markup`

### Requirement: Headings in message bodies
A body line starting with `# `, `## ` or `### ` SHALL use `neoment-heading` for the rest of the line.

#### Scenario: Second-level heading
- **WHEN** the body is `## Notes`
- **THEN** `Notes` has the face `neoment-heading`

### Requirement: Hidden markup characters
When `neoment-room-hide-markup` is non-nil (the default), the emphasis markers, the inline-code backticks and the heading `#` prefix with its space SHALL be invisible in room and thread buffers. When it is nil, they SHALL be visible in `neoment-markup`. Fence lines are never hidden.

#### Scenario: Default display
- **WHEN** Alice sends `**this**` at 09:12:44 with the default settings
- **THEN** the line reads `09:12:44               Alice │ this` with `this` in bold

#### Scenario: Markup shown
- **WHEN** `neoment-room-hide-markup` is nil and the body is `**this**`
- **THEN** the line shows `**this**`, the asterisks in `neoment-markup` and `this` in bold

### Requirement: Copy keeps markdown
Copying styled message text MUST include the markdown markers, hidden or not, so the copied text is the message's markdown.

#### Scenario: Copy a bold message
- **WHEN** the user copies the line showing a bold `this` sent as `**this**`
- **THEN** the kill ring receives `**this**`
