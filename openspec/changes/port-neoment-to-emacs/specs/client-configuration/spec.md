# Spec Delta

## Purpose

Defines how users configure and drive Neoment in Emacs: the user options and their validation, theme-aware faces and icons, the top-level commands, keymap conventions, user-facing message formatting, and optional transient integration.

## ADDED Requirements

### Requirement: Platform support
The package SHALL require Emacs 29.1 or newer and SHALL work in both GUI frames and `emacs -nw`. Images and popups are limited to GUI frames. Quitting Emacs while requests are in flight SHALL NOT ask for confirmation.

#### Scenario: Terminal use
- **WHEN** Neoment runs in `emacs -nw`
- **THEN** all features except inline images and graphical popups work

#### Scenario: Quit during sync
- **WHEN** the user quits Emacs while a sync request is in flight
- **THEN** Emacs exits without asking about active processes

### Requirement: User options
The package SHALL define a `neoment` customisation group that holds every option in emacs-port.md §4 (session saving, login method, notifier, desktop notifications, pickers, attachment handler, room-list display and icons), with the types and defaults listed there, except `neoment-desktop-notifications-source` and the custom level options (`neoment-desktop-notifications-buffer`, `-favorites`, `-people`, `-rooms`, `-per-room`), which are not ported.

#### Scenario: Defaults
- **WHEN** no options are customised
- **THEN** sessions are saved, desktop notifications are enabled, and the room title format is `room_space`

### Requirement: Option validation
An invalid value of `neoment-login-method` SHALL produce a warning. `neoment-reload-config` SHALL run validation again and show `Configuration reloaded`.

#### Scenario: Invalid login method
- **WHEN** `neoment-login-method` is set to `foo`
- **THEN** a warning is shown

### Requirement: Message prefix and notifier
Every user-facing message SHALL be prefixed with `[Neoment] ` and sent through `neoment-notifier` (a function of message and level), which defaults to `message`.

#### Scenario: Custom notifier
- **WHEN** the user sets `neoment-notifier` to a custom function
- **THEN** all Neoment messages go to that function with their level

### Requirement: Faces
The package SHALL define the `neoment-*` faces listed in emacs-port.md §16, inheriting from standard faces so they follow the theme, plus 20 per-user sender faces. In bubble border faces, the foreground SHALL be the bubble content's background and the background SHALL be the default background. Border faces SHALL be recomputed when a theme is enabled.

#### Scenario: Theme switch
- **WHEN** the user loads a different theme
- **THEN** bubble border colours match the new bubble background

### Requirement: Icons
`neoment-icons` SHALL default to the Nerd Font glyphs listed in emacs-port.md §4.1 and be customisable per key. The bubble edge glyphs (U+E0B6, U+E0B4) are fixed and not customisable. In a GUI frame where `char-displayable-p` reports that they cannot be displayed, the client SHALL use `▐` (U+2590) and `▌` (U+258C) with the same border faces. Both are one column wide, so layouts are unchanged.

#### Scenario: Override icon
- **WHEN** the user sets the `room` icon to `#`
- **THEN** room lines use `#`

#### Scenario: GUI without Nerd Font
- **WHEN** no installed font can display U+E0B6 in a GUI frame
- **THEN** bubbles render as `▐<content>▌` with the border faces, and every column position is unchanged

### Requirement: Top-level commands
The package SHALL provide autoloaded interactive commands:
- `neoment`
- `neoment-join`, `neoment-logout`
- `neoment-pick-room`, `neoment-pick-open-room`
- `neoment-sync-start`, `neoment-sync-stop`
- `neoment-reload-config`, `neoment-clear-cache`
- `neoment-toggle-rooms-list`
- `neoment-notification-settings` (global notification settings)
- the dispatcher `neoment-command`, which offers these as subcommands with completion

#### Scenario: Dispatcher
- **WHEN** the user runs `neoment-command` and picks `logout`
- **THEN** the logout flow starts

### Requirement: Keymap conventions
The read-only buffers (rooms list, room, space, info) SHALL use single-letter bindings in keymaps derived from `special-mode`. Every binding SHALL call a named interactive command. `?` SHALL show the mode's key help.

#### Scenario: Help
- **WHEN** the user presses `?` in a room buffer
- **THEN** a list of the room-mode bindings is shown

### Requirement: Focus tracking
The client SHALL track whether an Emacs frame has focus, for notification suppression.

#### Scenario: Unfocused
- **WHEN** all Emacs frames lose focus
- **THEN** messages in the current room are eligible for notification
