# Spec Delta

## MODIFIED Requirements

### Requirement: Threads
`rel_type == "m.thread"` SHALL set `thread_root_id`. A root's `thread_replies_count` comes from `unsigned["m.relations"]["m.thread"].count`, which already includes the replies that existed when the server sent the root. A thread reply SHALL add one to the loaded root's count only when it arrives live (not in paginated history) and the root was loaded in an earlier batch. Otherwise the count SHALL stay unchanged.

#### Scenario: New thread reply
- **WHEN** root `$r` with count 2 was loaded in an earlier batch and a new reply in thread `$r` arrives live
- **THEN** the count becomes 3

#### Scenario: Root and replies in the same live batch
- **WHEN** one sync batch contains root `$r` with count 2 and its two thread replies
- **THEN** the count stays 2

#### Scenario: Root and replies in a history page
- **WHEN** a paginated history page contains root `$r` with count 2 and its two thread replies
- **THEN** the count stays 2

#### Scenario: Replies loaded before their root
- **WHEN** a history page contains thread replies to `$r`, and a later, older page contains root `$r` with count 2
- **THEN** the count is 2
