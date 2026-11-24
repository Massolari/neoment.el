# Spec Delta

## MODIFIED Requirements

### Requirement: Rooms list window
The room list SHALL live in a buffer named ` *neoment-rooms*` (with a leading space), which hides it from normal buffer switching. It SHALL be shown in a dedicated, fixed-width left side window, `min(50, floor(20% of frame width))` columns wide, with the current line highlighted and no line numbers. `neoment-toggle-rooms-list` SHALL close the window if it exists and open it otherwise.

#### Scenario: Toggle
- **WHEN** the room list window is visible and the user runs `neoment-toggle-rooms-list`
- **THEN** the window closes

#### Scenario: Width on a 300-column frame
- **WHEN** the frame is 300 columns wide
- **THEN** the side window is 50 columns wide

#### Scenario: Hidden buffer name
- **WHEN** the room list is open
- **THEN** its buffer is named ` *neoment-rooms*` and does not appear among the candidates of `switch-to-buffer`
