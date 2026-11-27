# session-management Specification

## Purpose

Keeps a Matrix session alive across Emacs restarts and token expiry. It saves and restores credentials and a compact cache, refreshes tokens safely, detects an expired session, and handles logout and cache clearing.

## Requirements

### Requirement: Session files
The client SHALL save credentials in `<user-emacs-directory>/neoment/data.json` (`user_id`, `homeserver`, `device_id`, `access_token`, `refresh_token`, `expires_at`, `refresh`, `last_save`) with file mode 0600. It SHALL also save `ui_state.json` and `oauth_clients.json` there, and `cache.json` plus `media/` in a cache directory. The default `device_id` SHALL be an Emacs-specific constant (e.g. `emacs-matrix-client`).

#### Scenario: Credentials file permissions
- **WHEN** the session is saved
- **THEN** `data.json` exists with mode 0600

### Requirement: Compact room cache
`cache.json` SHALL hold `sync_token`, `invited_rooms`, and a reduced form of each room: id, name, aliases, tombstone, avatar_url, topic, last_activity, unread_activity, is_direct, is_favorite, is_lowpriority, space_rooms, members, unread counts, joined_member_count, unread, read_receipt, fully_read, and only the last message. `events`, `pending_events`, `typing` and `prev_batch` MUST be empty, and `is_tracked` false.

#### Scenario: Room with many messages saved
- **WHEN** a tracked room with 50 loaded messages is saved
- **THEN** the cached room contains exactly one message and `is_tracked` is false

#### Scenario: Unread activity round trip
- **WHEN** a room whose unread activity differs from its last activity is saved and restored
- **THEN** the restored room has the same unread activity and the same unread state

### Requirement: Cached message key
The cached message SHALL be keyed by its effective id (the original event id, also for an edited message). Loading the cache SHALL store each message under the effective id of the loaded message, whatever key the file uses, so caches written with an edit's id as key load correctly.

#### Scenario: Edited last message survives a restart
- **WHEN** a room whose last message `$o` was edited by `$oe` is saved and loaded again
- **THEN** the cached message is keyed by `$o`, the loaded room finds it by `$o`, and it keeps its edited content and `edit_data`

#### Scenario: Cache written with the edit's id as key
- **WHEN** `cache.json` holds a message under the key `$oe` whose `edit_data.id` is `$o`
- **THEN** the loaded room stores the message under `$o`

### Requirement: Save cadence
The session SHALL be saved on login, after every 10th successful sync, and after every token refresh, when `neoment-save-session` is non-nil.

#### Scenario: Saving disabled
- **WHEN** `neoment-save-session` is nil and login succeeds
- **THEN** `data.json` and `cache.json` are not written (`oauth_clients.json` may still be written)

### Requirement: Session restore
Restore SHALL need an `access_token`. If there is no `refresh_token` and `last_save` is older than 7 days, it SHALL show `Session data is expired, please log in again` and fall back to normal login. With a refresh token, it SHALL restore regardless of age and show `Matrix session restored for <user_id>`.

#### Scenario: Old session without refresh token
- **WHEN** `data.json` has no refresh token and `last_save` is 8 days old
- **THEN** the session is not restored and the login prompt appears

#### Scenario: Old session with refresh token
- **WHEN** `data.json` has a refresh token and `last_save` is 30 days old
- **THEN** the session is restored

### Requirement: Proactive token refresh
Before each authenticated request, the client SHALL refresh first when a `refresh_token` and `expires_at` exist and fewer than 60 s remain. Only one refresh SHALL run at a time. Concurrent requests MUST wait for that refresh and get its result. The refresh SHALL time out after 30 s.

#### Scenario: Concurrent requests near expiry
- **WHEN** three requests are issued 30 s before expiry
- **THEN** exactly one refresh request is sent and all three proceed with the new token

### Requirement: Refresh methods
A legacy session (no `refresh` record) SHALL `POST /_matrix/client/v3/refresh` with `{refresh_token}`. An OAuth session SHALL POST form-encoded `grant_type=refresh_token`, `refresh_token`, `client_id` to its `token_endpoint`. The client SHALL keep the old refresh token when the response leaves it out, and set `expires_at` from `expires_in`.

#### Scenario: Refresh without rotated token
- **WHEN** the refresh response contains `access_token` and `expires_in` but no `refresh_token`
- **THEN** the previous refresh token is kept

### Requirement: Handling M_UNKNOWN_TOKEN
On `401 M_UNKNOWN_TOKEN`, the client SHALL resend once if the token changed since the request was sent. With `soft_logout: true` and a refresh token, it SHALL refresh and resend once. Otherwise the session SHALL be treated as expired.

#### Scenario: Soft logout
- **WHEN** a request fails with `M_UNKNOWN_TOKEN` and `soft_logout: true`
- **THEN** the client refreshes and retries that request exactly once

### Requirement: Refresh failure handling
On a permanent refresh failure (4xx other than 408/429), the client SHALL re-read `data.json` and adopt a different refresh token stored there for the same homeserver and user. If there is none, the session expires. Transient failures (network, 5xx, 408, 429) MUST NOT end the session.

#### Scenario: Token rotated by another instance
- **WHEN** refresh returns 400 and `data.json` holds a different refresh token for the same user and homeserver
- **THEN** that token is adopted and the session continues

#### Scenario: Transient refresh failure
- **WHEN** refresh fails with 503
- **THEN** the session stays active and the next request tries to refresh again

### Requirement: Session expiry
When the session expires, the client SHALL stop sync, delete the saved session, reset the client and show `Session expired, please log in again` exactly once, even when many requests fail at the same moment.

#### Scenario: Many failures at once
- **WHEN** five in-flight requests all fail with a non-soft `M_UNKNOWN_TOKEN`
- **THEN** the expiry message is shown once

### Requirement: Stale responses discarded
Responses to sync, refresh, or push-rule requests that a previous client instance issued (before logout or re-login) MUST NOT change the current client state.

#### Scenario: Response after logout
- **WHEN** a sync response arrives after the user logged out
- **THEN** it is discarded

### Requirement: Logout
`neoment-logout` SHALL ask `Are you sure you want to log out?\nAll saved data will be lost.` (default No; No → `Operation canceled`). An OAuth session that has a `revocation_endpoint` SHALL revoke its refresh token (RFC 7009). Other sessions SHALL `POST /_matrix/client/v3/logout`. On success it SHALL stop sync, delete `data.json`, `cache.json` and `ui_state.json`, reset the client and show `Logout successful`. On failure it SHALL show `Logout failed: <error>`.

#### Scenario: Confirmed logout keeps OAuth clients
- **WHEN** the user confirms logout and the server accepts it
- **THEN** session, cache and UI state files are deleted, and `oauth_clients.json` is kept

### Requirement: Clear cache
`neoment-clear-cache` SHALL delete `cache.json` and show `Neoment cache removed (<n>KB)`, or `No cache file found to remove` when the file does not exist.

#### Scenario: No cache file
- **WHEN** `cache.json` does not exist
- **THEN** `No cache file found to remove` is shown

### Requirement: Access token confidentiality
The access token MUST never appear in a URL. The `Authorization` header MUST be sent only to URLs that start with `<homeserver>/`.

#### Scenario: Third-party URL
- **WHEN** a request goes to a URL outside the homeserver
- **THEN** no `Authorization` header is sent

### Requirement: Quit Neoment
`neoment-quit` SHALL stop the sync loop, cancel Neoment's pending timers, delete the processes Neoment started, and kill every Neoment buffer without asking for confirmation. It SHALL show `Neoment closed` when done. It MUST NOT log out or delete `data.json`, `cache.json` or `ui_state.json`, and it MUST NOT contact the server. It SHALL work when not logged in or when nothing is open.

#### Scenario: Quit while syncing
- **WHEN** the user runs `neoment-quit` while the sync loop runs and room, rooms list and compose buffers are open
- **THEN** sync is stopped, all those buffers are killed, and `Neoment closed` is shown

#### Scenario: Session kept
- **WHEN** the user quits and later runs `neoment`
- **THEN** the saved session is restored without a login prompt

#### Scenario: Unsent compose text
- **WHEN** a compose buffer holds unsent text and the user runs `neoment-quit`
- **THEN** the buffer is killed without a confirmation prompt

#### Scenario: Nothing to quit
- **WHEN** the user runs `neoment-quit` while logged out with no Neoment buffers
- **THEN** no error occurs and `Neoment closed` is shown

### Requirement: Quit stops helper processes and timers
`neoment-quit` SHALL delete a running audio playback process and a running desktop notification process, and cancel the pending UI render timer and media popup timer. No Neoment timer or process SHALL remain after it returns.

#### Scenario: Audio playing
- **WHEN** an attachment is playing in `mpv` and the user runs `neoment-quit`
- **THEN** the `mpv` process and its `*neoment-mpv*` buffer are gone

#### Scenario: Render pending
- **WHEN** a UI render is scheduled and the user runs `neoment-quit`
- **THEN** the render does not run afterwards and no buffer is recreated

### Requirement: Quit from the room list
Pressing `Q` in the room list SHALL ask `Quit Neoment? ` (default No) and run `neoment-quit` only on a yes. `neoment-quit` itself SHALL NOT ask.

#### Scenario: Confirmed
- **WHEN** the user presses `Q` in the room list and answers yes
- **THEN** `neoment-quit` runs

#### Scenario: Declined
- **WHEN** the user presses `Q` in the room list and answers no
- **THEN** `Operation canceled` is shown and sync, buffers and processes are left untouched

### Requirement: Quit command access
`neoment-quit` SHALL be reachable from the Neoment menu and from the `neoment-command` subcommand `quit`.

#### Scenario: Subcommand
- **WHEN** the user picks `quit` in `neoment-command`
- **THEN** `neoment-quit` runs

### Requirement: Cache without unread activity
When a cached room has no `unread_activity` key, as in a cache written by an older version, the restored room SHALL use its `last_activity` as unread activity. A null `unread_activity` SHALL restore as no unread activity.

#### Scenario: Cache from an older version
- **WHEN** a cached room has `last_activity` but no `unread_activity`
- **THEN** the restored room's unread activity equals its last activity

#### Scenario: Room without unread activity
- **WHEN** a room with last activity but no unread activity is saved and restored
- **THEN** the restored room has no unread activity and stays read
