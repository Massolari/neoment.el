# Spec Delta

## MODIFIED Requirements

### Requirement: Open attachment
`o` (or mouse-1) on a spoiler link SHALL show its content in the echo area, and on any other non-`mxc://` link SHALL open the URL with `browse-url`. Otherwise, `o` on an `mxc://` emoticon or reaction SHALL download it as `<sanitised title>.png` and call the handler with origin `emoticon`/`reaction`. Otherwise it uses the message attachment, downloads it to `<event_id><filename>` in the media directory (showing `Fetching attachment <f>...` and `Opening attachment <f>...`), and calls `neoment-on-open-attachment-function` with the path and the attachment, origin `message`. Locations pass the map URL.

#### Scenario: No attachment
- **WHEN** the message has no attachment
- **THEN** `No attachment on this message` is shown

#### Scenario: Location without URL
- **WHEN** a location attachment has no URL
- **THEN** `No URL for this location attachment` is shown

#### Scenario: Open a link
- **WHEN** the cursor is on the visible text `docs` of `[docs](https://example.org)` and the user presses `o`
- **THEN** `https://example.org` is opened with `browse-url` and no attachment is fetched

#### Scenario: Reveal a spoiler
- **WHEN** the cursor is on `Spoiler` of `[Spoiler](<the end>)` and the user presses `o`
- **THEN** the echo area shows `the end`
