# Spec Delta

## MODIFIED Requirements

### Requirement: Default open handler
By default, audio files SHALL play in the controlled audio player (see `audio-player`) when `mpv` is available and supported on the platform, and the player window SHALL be shown. Everything else SHALL open with the system program.

#### Scenario: Audio with mpv installed
- **WHEN** the user opens an audio attachment and `mpv` is on PATH
- **THEN** the audio player starts and its state window is shown

#### Scenario: Non-audio file
- **WHEN** the user opens a PDF attachment
- **THEN** it opens with the system program
