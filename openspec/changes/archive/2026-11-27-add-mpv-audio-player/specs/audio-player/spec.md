# Spec Delta

## Purpose
Lets the user listen to audio attachments inside Emacs with real player controls (pause, seek, speed), using `mpv` as the playback engine, without needing an interactive terminal.

## ADDED Requirements

### Requirement: Controlled playback
Playing an audio file SHALL start `mpv` without video and without a terminal, controllable from Emacs. Only one player SHALL exist at a time: playing another file stops the current one first.

#### Scenario: Play a second file
- **WHEN** audio A is playing and the user opens audio B
- **THEN** A stops and B starts

### Requirement: Playback controls
The player SHALL provide commands to toggle pause/resume, seek backward and forward by `neoment-player-seek-step` seconds (default 10), increase and decrease speed by `neoment-player-speed-step` (default 0.25), reset speed to 1.0, and stop. Speed SHALL NOT go below 0.25. With no active player each command SHALL show `No audio playing`.

#### Scenario: Pause and resume
- **WHEN** the user toggles pause twice while audio plays
- **THEN** playback pauses, then resumes from the same position

#### Scenario: Seek past the start
- **WHEN** the user seeks backward 10 seconds at position 0:03
- **THEN** playback continues from 0:00

#### Scenario: Speed up
- **WHEN** the speed is 1.0 and the user increases it
- **THEN** the speed becomes 1.25

#### Scenario: Nothing playing
- **WHEN** the user toggles pause with no player
- **THEN** `No audio playing` is shown

### Requirement: Player state display
A read-only `*neoment-player*` buffer SHALL be shown in a small window and SHALL display the file name, a play or pause indicator, the position and duration as `m:ss`, the speed when it differs from 1.0, the volume, and `muted` when muted. It SHALL update as playback progresses, including when volume or mute change.

#### Scenario: Playing
- **WHEN** a 75 second clip is at 42 seconds at speed 1.5 and volume 80
- **THEN** the buffer shows the playing indicator, `0:42 / 1:15`, `1.5x` and `vol 80`

#### Scenario: Muted
- **WHEN** the user presses `m` in the player buffer
- **THEN** the buffer shows `muted`

### Requirement: Key forwarding
While `neoment-player-forward-keys` is non-nil (default), every unmodified key typed in `*neoment-player*` SHALL be sent to mpv as that key, so mpv's bindings, including the user's `input.conf`, apply. Forwarded keys are printable characters, `SPC`, `RET`, `TAB`, `DEL`, the arrow keys, `Home`/`End`, `PgUp`/`PgDn` and `F1`–`F12`. Keys with `C-` or `M-` modifiers SHALL NOT be forwarded and keep their Emacs meaning. `q` SHALL NOT be forwarded: it stops the player and closes the window. When the option is nil, only the dedicated bindings `SPC` pause, `<left>`/`<right>` seek, `[`/`]` slower/faster, `=` reset speed and `q` stop apply. Keys mpv cannot act on without a window (fullscreen, stats overlay, on-screen display) have no visible effect.

#### Scenario: Speed key
- **WHEN** the user presses `]` in the player buffer
- **THEN** mpv receives the key `]` and the displayed speed changes

#### Scenario: Special key
- **WHEN** the user presses `<left>`
- **THEN** mpv receives the key `LEFT`

#### Scenario: Chord not forwarded
- **WHEN** the user presses `C-x`
- **THEN** nothing is sent to mpv and Emacs handles the prefix

#### Scenario: Quit
- **WHEN** the user presses `q`
- **THEN** the player stops and its window closes

#### Scenario: Forwarding disabled
- **WHEN** `neoment-player-forward-keys` is nil and the user presses `m`
- **THEN** nothing is sent to mpv

### Requirement: Player menu
`neoment-player-menu` SHALL be a transient exposing every control, usable from any buffer.

#### Scenario: Control from the room buffer
- **WHEN** the user opens the menu from a room buffer and picks seek forward
- **THEN** playback jumps ahead without switching windows

### Requirement: Lifecycle and cleanup
When mpv exits, by itself or after stop, the player SHALL release its control channel and remove the control socket file, and SHALL show `Playback finished` when the file ended on its own. Quitting Emacs MUST NOT leave an mpv process behind. If mpv fails to start or its control channel cannot be opened, the client SHALL show `Could not start mpv` with the reason.

#### Scenario: End of file
- **WHEN** the clip reaches its end
- **THEN** `Playback finished` is shown and no mpv process remains

#### Scenario: Emacs exit
- **WHEN** the user quits Emacs while audio plays
- **THEN** the mpv process is terminated

### Requirement: Fallback without mpv
When `mpv` is not on PATH, or the platform cannot reach mpv's control channel (Windows), audio SHALL open with the system program instead.

#### Scenario: mpv not installed
- **WHEN** the user opens audio and `mpv` is not on PATH
- **THEN** the file opens with the system program
