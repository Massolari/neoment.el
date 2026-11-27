# Spec Delta

## MODIFIED Requirements

### Requirement: Refresh room state
`u` SHALL show `Refreshing state for <n>...` and `GET /rooms/<r>/state`, applying only tombstone, name, topic, canonical_alias and space.child. It then shows `State updated for <n>` or `No new state for <n>`. `<n>` SHALL be the room's display name, not its raw `name`.

#### Scenario: No change
- **WHEN** the fetched state matches local state
- **THEN** `No new state for <n>` is shown

#### Scenario: Room named only by its alias
- **WHEN** the user presses `u` on a room with no explicit name and alias `#dev:s`
- **THEN** `Refreshing state for #dev:s...` is shown
