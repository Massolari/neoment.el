# Spec Delta

## ADDED Requirements

### Requirement: Redacted messages are not notification text
A message marked `was_redacted` (redacted live or already redacted on the server) SHALL NOT be used as the push-rule notification candidate or as the stored-message fallback. A candidate that is redacted before the notification is sent SHALL be dropped, and the fallback used instead.

#### Scenario: Newer message already redacted
- **WHEN** one sync brings Bob's message `hi` and then a later server-redacted message, and the notification count rises
- **THEN** the desktop notification shows `hi`

#### Scenario: Candidate redacted in the same sync
- **WHEN** one sync brings Bob's message `hi`, then `spam`, then a redaction of `spam`, and the notification count rises
- **THEN** the desktop notification shows `hi`, not `[Redacted…]`
