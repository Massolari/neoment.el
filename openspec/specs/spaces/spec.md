# spaces Specification

## Purpose

Lets the user browse a Matrix space's full hierarchy, including rooms they have not joined, and open or join rooms and sub-spaces from it.

## Requirements

### Requirement: Space buffer
Opening a space SHALL show the buffer `*neoment-space: <name>*`, without the space ID, with initial content `Loading space...`. It SHALL then fetch `GET /_matrix/client/v1/rooms/<space>/hierarchy`. On failure it shows `Failed to fetch space hierarchy: <e>`.

#### Scenario: Hierarchy fails
- **WHEN** the hierarchy request returns 403
- **THEN** `Failed to fetch space hierarchy: <e>` is shown

#### Scenario: Space buffer name
- **WHEN** the user opens space `!sp:s`, named `Neovim Brasil`
- **THEN** the buffer is named `*neoment-space: Neovim Brasil*`

### Requirement: Space layout
The buffer SHALL show, in order: the space name (title face), an empty line, `Topic:` (bold), then the non-empty topic lines or `No topic`, an empty line, `Rooms:` (bold), then the tree. Each tree line is `<indent><icon>  <name> (<n> members)`, followed by ` - <first topic line...>` in the comment face when there is a topic. The root space comes first. Joined rooms carry an inline `Joined` bubble.

#### Scenario: Unnamed child
- **WHEN** a child has an empty name and is unknown locally
- **THEN** it is shown as `(No Name)`

#### Scenario: Empty space
- **WHEN** the hierarchy has no children
- **THEN** `  No rooms in this space` is shown

### Requirement: Hierarchy order
Children SHALL follow the `children_state` of each space, recursively, with each room or space listed once.

#### Scenario: Room in two sub-spaces
- **WHEN** a room is a child of two sub-spaces
- **THEN** it appears only once

### Requirement: Space actions
RET on an item the user has not joined SHALL ask `Do you want to join this room?` (Join/Cancel). Join uses the `via` servers from `m.space.child` and then opens the room. RET on a joined space opens the space buffer, and on a joined room opens the room. RET on a non-item line shows `No room or space under the cursor`. `q` kills the buffer, `g` reloads, and `f`, `F`, `l` work as in the room buffer.

#### Scenario: Join from space
- **WHEN** the user confirms Join on an unjoined room
- **THEN** a join request with the child's `via` servers is sent, and the room opens on success
