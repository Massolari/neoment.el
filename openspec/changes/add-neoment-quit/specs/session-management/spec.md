## ADDED Requirements

### Requirement: Quit Neoment
`neoment-quit` SHALL stop the sync loop, cancel Neoment's pending timers, delete the processes Neoment started, and kill every Neoment buffer without asking for confirmation. It SHALL show `Neoment closed` when done. It MUST NOT log out or delete `data.json`, `cache.json` or `ui_state.json`, and it MUST NOT contact the server. It SHALL work when not logged in or when nothing is open.

#### Scenario: Quit while syncing
- **WHEN** the user runs `neoment-quit` while the sync loop runs and room, rooms list and compose buffers are open
- **THEN** sync is stopped, all those buffers are killed, and `Neoment closed` is shown

#### Scenario: Session kept
- **WHEN** the user quits and later runs `neoment`
- **THEN** the saved session is restored without a login prompt

#### Scenario: Unsent compose text
- **WHEN** a compose buffer holds unsent text and the user runs `neoment-quit`
- **THEN** the buffer is killed without a confirmation prompt

#### Scenario: Nothing to quit
- **WHEN** the user runs `neoment-quit` while logged out with no Neoment buffers
- **THEN** no error occurs and `Neoment closed` is shown

### Requirement: Quit stops helper processes and timers
`neoment-quit` SHALL delete a running audio playback process and a running desktop notification process, and cancel the pending UI render timer and media popup timer. No Neoment timer or process SHALL remain after it returns.

#### Scenario: Audio playing
- **WHEN** an attachment is playing in `mpv` and the user runs `neoment-quit`
- **THEN** the `mpv` process and its `*neoment-mpv*` buffer are gone

#### Scenario: Render pending
- **WHEN** a UI render is scheduled and the user runs `neoment-quit`
- **THEN** the render does not run afterwards and no buffer is recreated

### Requirement: Quit from the room list
Pressing `Q` in the room list SHALL ask `Quit Neoment? ` (default No) and run `neoment-quit` only on a yes. `neoment-quit` itself SHALL NOT ask.

#### Scenario: Confirmed
- **WHEN** the user presses `Q` in the room list and answers yes
- **THEN** `neoment-quit` runs

#### Scenario: Declined
- **WHEN** the user presses `Q` in the room list and answers no
- **THEN** `Operation canceled` is shown and sync, buffers and processes are left untouched

### Requirement: Quit command access
`neoment-quit` SHALL be reachable from the Neoment menu and from the `neoment-command` subcommand `quit`.

#### Scenario: Subcommand
- **WHEN** the user picks `quit` in `neoment-command`
- **THEN** `neoment-quit` runs
