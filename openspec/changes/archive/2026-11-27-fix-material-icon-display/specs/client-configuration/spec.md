# Spec Delta

## ADDED Requirements

### Requirement: Nerd Font routing for icons
Before rendering in a GUI frame, the client SHALL map each private-use character in the configured icons, the default icons and the bubble edges to the font family named by `neoment-icon-font-family` (default `"Symbols Nerd Font Mono"`). It SHALL do this only when that family is installed, and SHALL append the mapping to the default fontset so fonts the user already configured for those characters take precedence. A `nil` option disables the mapping. Terminal frames are unaffected.

#### Scenario: Plane-15 icon with a non-Nerd default font
- **WHEN** the default font is Iosevka, `Symbols Nerd Font Mono` is installed, and the room list is shown in a GUI frame
- **THEN** the room icon U+F0BA7 is drawn with `Symbols Nerd Font Mono` instead of a hex box

#### Scenario: User font for the code point wins
- **WHEN** the user has already set a font for U+F0BA7 in the default fontset
- **THEN** that font is still used for U+F0BA7

#### Scenario: Family not installed
- **WHEN** `neoment-icon-font-family` names a family that is not installed
- **THEN** the default fontset is not modified

#### Scenario: Routing disabled
- **WHEN** `neoment-icon-font-family` is `nil`
- **THEN** the default fontset is not modified

### Requirement: Plain icon fallback
The client SHALL provide `neoment-plain-icons`, an alist with a single-column plain Unicode string for every key of `neoment-default-icons`. In a GUI frame, when the icon for a key is still its default Nerd glyph and some character of it cannot be displayed, the client SHALL use that key's plain icon. Icons the user customised are used unchanged. Terminal frames always use the configured icon.

#### Scenario: Default icon not displayable
- **WHEN** no installed font can display U+F0BA7 in a GUI frame and `room` has its default value
- **THEN** room lines use the plain `room` icon `#`

#### Scenario: Customised icon not displayable
- **WHEN** the user sets `room` to a glyph that no font can display
- **THEN** room lines use the user's glyph unchanged

#### Scenario: Default icon displayable
- **WHEN** U+F0BA7 can be displayed in the GUI frame
- **THEN** room lines use `󰮧`

#### Scenario: Terminal frame
- **WHEN** the room list renders in a terminal frame
- **THEN** every icon is the configured one, with no displayability check

#### Scenario: Preset as user setting
- **WHEN** the user sets `neoment-icons` to `neoment-plain-icons`
- **THEN** every icon is plain in both GUI and terminal frames
