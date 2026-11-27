# Spec Delta

## MODIFIED Requirements

### Requirement: Room mode key bindings
`neoment-room-mode` SHALL bind:
- `RET` compose, `r` reply, `e` edit, `t` thread
- `n`/`p` next/previous message
- `a`/`A` react (emoji/text), `d` redact, `w` forward
- `R` go to replied message, `m` set read marker, `V` show event
- `P` load previous, `L` leave
- `o`/`s` open/save attachment, `u`/`U` upload/upload clipboard, `z` zoom
- `O` audio player menu
- `i` info, `N` notification settings
- `f`/`F` pickers, `l` toggle the room list
- `q` quit, `g` revert

Each key SHALL call a named interactive command.

#### Scenario: Remap
- **WHEN** the user binds another key to `neoment-room-reply` in `neoment-room-mode-map`
- **THEN** that key starts a reply

#### Scenario: Player menu key
- **WHEN** the user presses `O` in a room buffer
- **THEN** the audio player menu opens
