# Spec Delta

## MODIFIED Requirements

### Requirement: Compose buffer naming
The buffer name SHALL be one of:
- `*neoment-compose: Sending to <room>*`
- `*neoment-compose: Sending to thread in <room>*`
- `*neoment-compose: Replying to <sender>*`
- `*neoment-compose: Editing message on <room>*`

Each gets the suffix ` with the attachment <filename>` inside the closing `*` when an attachment is attached.

#### Scenario: Reply with attachment
- **WHEN** the user uploads `a.png` while replying to Alice
- **THEN** the buffer is named `*neoment-compose: Replying to Alice with the attachment a.png*`

#### Scenario: Plain message
- **WHEN** the user starts a new message in room `dev`
- **THEN** the buffer is named `*neoment-compose: Sending to dev*`
