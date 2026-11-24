# Spec Delta

## MODIFIED Requirements

### Requirement: HTML to markdown inline and special elements
For display, the converter SHALL turn:
- `<strong>`/`<b>` into `**`, `<em>`/`<i>` into `*`, `<del>`/`<s>`/`<strike>` into `~~`, `<a href>` into `[t](url)`
- tags with `data-md="x"` into `x content x`
- `<p data-mx-forwarded-notice>` into `_↪️ Forwarded:_` plus an empty line
- spoilers into `[Spoiler](content)` or `[Spoiler for <desc>](content)`, with content always in `<…>` (tags dropped, entities decoded, `\`, `<` and `>` escaped by a backslash and newlines written as `\n`)
- `<img data-mx-emoticon>` into `[img: title](src)`

Unknown tags are dropped but their content kept. Entities are decoded at the end.

#### Scenario: Emoticon
- **WHEN** the HTML is `<img data-mx-emoticon src="mxc://s/a" title=":party:">`
- **THEN** the markdown is `[img: :party:](mxc://s/a)`

#### Scenario: Spoiler with spaces
- **WHEN** the HTML is `<span data-mx-spoiler>a b</span>`
- **THEN** the markdown is `[Spoiler](<a b>)`

#### Scenario: Strikethrough
- **WHEN** the HTML is `<del>old</del> new`
- **THEN** the markdown is `~~old~~ new`
