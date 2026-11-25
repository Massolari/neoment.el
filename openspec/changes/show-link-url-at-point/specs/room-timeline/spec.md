# Spec Delta

## ADDED Requirements

### Requirement: Link URL at point
After about 0.5 s idle with the cursor on a link's visible text in a room or thread buffer, the echo area SHALL show the link's URL, in GUI and terminal frames. Moving the cursor and idling again on another link SHALL show that link's URL. A spoiler SHALL show nothing. An `mxc://` emoticon SHALL keep its hover popup instead. The mouse tooltip on link text SHALL still show the URL.

#### Scenario: Cursor on a link
- **WHEN** the body is `see [docs](https://example.org)` and the cursor rests on `docs` for 0.5 s, in a GUI or a terminal frame
- **THEN** the echo area shows `https://example.org` and no popup frame is shown

#### Scenario: Cursor on a mention
- **WHEN** the cursor rests on the mention `Alice` of `[Alice](https://matrix.to/#/@alice:s)`
- **THEN** the echo area shows `https://matrix.to/#/@alice:s`

#### Scenario: Cursor on a spoiler
- **WHEN** the cursor rests on `Spoiler` of `[Spoiler](<the end>)`
- **THEN** nothing is shown and `the end` does not appear in the echo area

#### Scenario: Cursor on an emoticon
- **WHEN** the cursor rests on an `mxc://` emoticon link in a GUI frame
- **THEN** the emoticon popup is shown as before, not the `mxc://` URL

#### Scenario: Cursor off a link
- **WHEN** the cursor rests on plain body text
- **THEN** no URL is shown

#### Scenario: Mouse hover keeps the tooltip
- **WHEN** the mouse hovers over the link text `docs`
- **THEN** the tooltip (or the echo area, with `tooltip-mode` off) shows `https://example.org`
