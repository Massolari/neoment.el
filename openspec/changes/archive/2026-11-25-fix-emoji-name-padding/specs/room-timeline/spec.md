# Spec Delta

## ADDED Requirements

### Requirement: Sender name display width
The 19-column sender name limit in the message header line SHALL be measured as displayed width, counting composed glyphs (emoji with variation selectors, ZWJ sequences, combining marks) as they display. Truncation SHALL keep only whole glyphs. Rendering a message header SHALL NOT fail for any sender name, and the header SHALL stay 31 columns wide.

#### Scenario: Name of emoji with variation selectors
- **WHEN** the sender name is twenty `❤️` (heart + U+FE0F, each displayed 2 columns wide)
- **THEN** the room renders without error
- **AND** the gutter shows whole `❤️` glyphs taking at most 19 columns, right-aligned with leading spaces so the header is 31 columns

#### Scenario: Wide characters that do not fill the column exactly
- **WHEN** the sender name is twenty fullwidth characters, each 2 columns wide
- **THEN** the gutter shows nine of them (18 columns) preceded by one space

#### Scenario: Name of ZWJ emoji sequences
- **WHEN** the sender name is a series of ZWJ family emoji (e.g. `👨‍👩‍👧‍👦`)
- **THEN** each family shows whole or not at all, and the header is 31 columns wide
