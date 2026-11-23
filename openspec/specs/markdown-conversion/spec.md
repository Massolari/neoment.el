# markdown-conversion Specification

## Purpose

Converts between the user's lightweight markdown and Matrix `org.matrix.custom.html`: markdown to HTML when sending, HTML to readable markdown when displaying. Behaviour matches the original Neoment converter rather than full CommonMark.

## Requirements

### Requirement: Code is preserved when sending
Fenced blocks ```` ```lang ```` SHALL become `<pre><code class="language-lang">`, fences without a language `<pre><code>`, and inline `` `x` `` `<code>x</code>`. Their contents are HTML-escaped and not processed further.

#### Scenario: Bold inside code
- **WHEN** the input is `` `**x**` ``
- **THEN** the output is `<code>**x**</code>`

### Requirement: Block and inline formatting when sending
When sending, the converter SHALL:
- escape `& < >`
- turn consecutive `> ` lines into one `<blockquote>`
- turn `>!text<!` and `>! line` into `<span data-mx-spoiler>`
- turn `[t](url)` into `<a href>`
- turn `**`/`__` into `<strong>`, and `*`/`_` into `<em>`
- turn `#`, `##`, `###` into `<h1..3>`
- turn `- ` and `* ` into `<li>` grouped in `<ul>`
- turn newlines into `<br />`

`@local:server` mentions MUST NOT be formatted.

#### Scenario: Underscore in mention
- **WHEN** the input is `hi @foo_bar_baz:s`
- **THEN** no `<em>` is produced inside the mention

#### Scenario: Blockquote
- **WHEN** the input is `> a\n> b`
- **THEN** one `<blockquote>` containing both lines is produced

### Requirement: HTML to markdown structure
For display, the converter SHALL turn:
- `<p>` into lines, and `<br>` variants into `\n`
- `<pre><code class="language-x">` into a ```` ```x ```` block, `<pre><code>` into a plain fence, and `<code>` into backticks, decoding entities inside code
- `<blockquote>` lines into lines prefixed with `┃ `
- `<li>` into `- `
- `<h1..3>` into `#`

It SHALL remove `<mx-reply>…</mx-reply>` entirely.

#### Scenario: Reply fallback stripped
- **WHEN** `formatted_body` begins with an `<mx-reply>` block
- **THEN** the rendered markdown does not contain the quoted fallback

### Requirement: HTML to markdown inline and special elements
For display, the converter SHALL turn:
- `<strong>`/`<b>` into `**`, `<em>`/`<i>` into `*`, `<a href>` into `[t](url)`
- tags with `data-md="x"` into `x content x`
- `<p data-mx-forwarded-notice>` into `_↪️ Forwarded:_` plus an empty line
- spoilers into `[Spoiler](content)` or `[Spoiler for <desc>](content)`, with content in `<…>` when it contains spaces
- `<img data-mx-emoticon>` into `[img: title](src)`

Unknown tags are dropped but their content kept. Entities are decoded at the end.

#### Scenario: Emoticon
- **WHEN** the HTML is `<img data-mx-emoticon src="mxc://s/a" title=":party:">`
- **THEN** the markdown is `[img: :party:](mxc://s/a)`

#### Scenario: Spoiler with spaces
- **WHEN** the HTML is `<span data-mx-spoiler>a b</span>`
- **THEN** the markdown is `[Spoiler](<a b>)`
