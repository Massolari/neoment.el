# Spec Delta

## Purpose

Keeps a Matrix session alive across Emacs restarts and token expiry. It saves and restores credentials and a compact cache, refreshes tokens safely, detects an expired session, and handles logout and cache clearing.

## ADDED Requirements

### Requirement: Session files
The client SHALL save credentials in `<user-emacs-directory>/neoment/data.json` (`user_id`, `homeserver`, `device_id`, `access_token`, `refresh_token`, `expires_at`, `refresh`, `last_save`) with file mode 0600. It SHALL also save `ui_state.json` and `oauth_clients.json` there, and `cache.json` plus `media/` in a cache directory. The default `device_id` SHALL be an Emacs-specific constant (e.g. `emacs-matrix-client`).

#### Scenario: Credentials file permissions
- **WHEN** the session is saved
- **THEN** `data.json` exists with mode 0600

### Requirement: Compact room cache
`cache.json` SHALL hold `sync_token`, `invited_rooms`, and a reduced form of each room: id, name, aliases, tombstone, avatar_url, topic, last_activity, is_direct, is_favorite, is_lowpriority, space_rooms, members, unread counts, joined_member_count, unread, read_receipt, and only the last message. `events`, `pending_events`, `typing` and `prev_batch` MUST be empty, and `is_tracked` false.

#### Scenario: Room with many messages saved
- **WHEN** a tracked room with 50 loaded messages is saved
- **THEN** the cached room contains exactly one message and `is_tracked` is false

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
