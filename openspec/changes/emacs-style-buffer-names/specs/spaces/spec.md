# Spec Delta

## MODIFIED Requirements

### Requirement: Space buffer
Opening a space SHALL show the buffer `*neoment-space: <name>*`, without the space ID, with initial content `Loading space...`. It SHALL then fetch `GET /_matrix/client/v1/rooms/<space>/hierarchy`. On failure it shows `Failed to fetch space hierarchy: <e>`.

#### Scenario: Hierarchy fails
- **WHEN** the hierarchy request returns 403
- **THEN** `Failed to fetch space hierarchy: <e>` is shown

#### Scenario: Space buffer name
- **WHEN** the user opens space `!sp:s`, named `Neovim Brasil`
- **THEN** the buffer is named `*neoment-space: Neovim Brasil*`
