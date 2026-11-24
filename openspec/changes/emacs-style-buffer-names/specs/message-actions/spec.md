# Spec Delta

## MODIFIED Requirements

### Requirement: Threads
`t` on a thread root or thread reply SHALL open or focus the thread buffer `*neoment-thread: <author name> in <room name>*` in a window to the right. The name SHALL NOT contain the root event ID. The buffer starts as `Loading thread...`. On a message outside a thread, `t` SHALL open compose to start a thread on it.

#### Scenario: Start thread
- **WHEN** the user presses `t` on a message with no thread
- **THEN** compose opens titled `Sending to thread in <room>`

#### Scenario: Open thread buffer
- **WHEN** the user presses `t` on a thread root sent by Alice in room `dev`
- **THEN** the buffer `*neoment-thread: Alice in dev*` opens in a window to the right
