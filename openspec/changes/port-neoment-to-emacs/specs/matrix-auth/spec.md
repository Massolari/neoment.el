# Spec Delta

## Purpose

Signs the user in to a Matrix homeserver from Emacs. It finds the homeserver, picks a supported login method, and runs the OAuth 2.0 device code, password, or SSO flow, using the same prompts and messages as the original Neoment.

## ADDED Requirements

### Requirement: Login entry point
`M-x neoment` SHALL toggle the room list when a session is active. Otherwise it SHALL start a login. Each login attempt SHALL cancel any previous attempt (close the SSO listener, cancel OAuth polling) and bump a generation counter. Callbacks that belong to an older generation MUST be ignored.

#### Scenario: Already logged in
- **WHEN** the user runs `M-x neoment` with an active session
- **THEN** the room list window is toggled and no login prompt appears

#### Scenario: Stale login callback ignored
- **WHEN** a second login starts while the first one's OAuth poll is still in flight
- **THEN** the first poll is cancelled and any late response from it changes no client state

### Requirement: Restore before prompting
Before asking for credentials, a login SHALL try to restore the saved session. If the restore succeeds, it SHALL start sync and open the room list without prompting.

#### Scenario: Saved session exists
- **WHEN** `M-x neoment` runs and a valid `data.json` exists
- **THEN** the message `[Neoment] Matrix session restored for <user_id>` is shown and sync starts

### Requirement: Matrix ID or server input
The login SHALL prompt `Matrix ID or server: ` and parse the answer as a full Matrix ID (`@user:server` → server name plus user id), a bare server name, or an `http(s)` homeserver URL (trailing `/` stripped, no discovery).

#### Scenario: Full Matrix ID
- **WHEN** the user enters `@alice:example.org`
- **THEN** the server name is `example.org` and the user id `@alice:example.org` is remembered for the password flow

#### Scenario: Explicit URL
- **WHEN** the user enters `https://matrix.example.org/`
- **THEN** the homeserver is `https://matrix.example.org` and no `.well-known` lookup happens

#### Scenario: Empty or invalid input
- **WHEN** the user enters an empty string
- **THEN** `Login cancelled` is shown
- **WHEN** the user enters something that is none of the accepted forms
- **THEN** `Invalid Matrix ID or server: <input>` is shown

### Requirement: Homeserver discovery
Discovery SHALL show `Looking up the homeserver for <server>...` and `GET https://<hostname>/.well-known/matrix/client` (port removed) with a 5 s connect timeout and a 10 s total timeout. It SHALL use `m.homeserver.base_url` when that is an http(s) URL. Otherwise it falls back to `https://<server_name>`. Discovery MUST never fail the login.

#### Scenario: Well-known missing
- **WHEN** the `.well-known` request returns 404 or times out
- **THEN** the homeserver becomes `https://<server_name>` and login continues

#### Scenario: Client reset on new homeserver
- **WHEN** discovery resolves a homeserver
- **THEN** the client state is reset for that homeserver and only `device_id` is kept

### Requirement: Login method detection
The client SHALL fetch `GET <hs>/_matrix/client/v3/login` and `GET <hs>/_matrix/client/v1/auth_metadata` in parallel. It SHALL offer `password` for `m.login.password` and `sso` only when both `m.login.sso` and `m.login.token` are present. It SHALL offer `oauth_device` when the metadata has the device-code grant and valid http(s) URLs for `issuer`, `device_authorization_endpoint`, `token_endpoint` and `registration_endpoint`. Methods are ordered oauth_device, password, sso.

#### Scenario: SSO without token flow
- **WHEN** `/login` lists `m.login.sso` but not `m.login.token`
- **THEN** `sso` is not offered

#### Scenario: No supported method
- **WHEN** neither endpoint yields a supported method
- **THEN** `No supported login method. The server offers: <flows>` is shown
- **WHEN** the `/login` request itself failed
- **THEN** `Could not fetch login methods from <hs>: <error>` is shown

### Requirement: Login method selection
If `neoment-login-method` is set, the client SHALL use it. If the server does not offer that method, it SHALL show `Login method '<m>' is not offered by the server. It offers: <list>`. Otherwise it SHALL use `oauth_device` without asking when available, or the only method when there is one. With several methods, it SHALL prompt `Login method:` with the labels `Password`, `Single Sign-On (browser)`, `OAuth (device code)`.

#### Scenario: OAuth preferred silently
- **WHEN** the server offers oauth_device and password and no method is configured
- **THEN** OAuth device code login starts without a prompt

#### Scenario: User cancels method choice
- **WHEN** the method prompt is cancelled
- **THEN** `Login cancelled` is shown

### Requirement: Password login
Password login SHALL prompt `Username: ` (only if no Matrix ID was entered) and `Password: ` with hidden input. An empty answer to either SHALL cancel with `Login cancelled`. It SHALL `POST /_matrix/client/v3/login` with type `m.login.password`, identifier `m.id.user`, `refresh_token: true` and the `device_id`. It SHALL store the access token, refresh token, `expires_at` and `user_id`, and switch to `well_known.m.homeserver.base_url` if the response includes one.

#### Scenario: Successful password login
- **WHEN** the server returns `access_token`, `refresh_token`, `expires_in_ms` and `user_id`
- **THEN** `expires_at` = now + `expires_in_ms`/1000 and the login completes

### Requirement: OAuth client registration
OAuth login SHALL reuse a `client_id` saved per `issuer` in `oauth_clients.json`. If there is none, it SHALL register one by POSTing to `registration_endpoint` (device-code and refresh-token grants, `token_endpoint_auth_method: "none"`, `application_type: "native"`). `oauth_clients.json` MUST survive logout and MUST be written even when session saving is disabled.

#### Scenario: Invalid client
- **WHEN** the device authorization request returns `invalid_client`
- **THEN** the saved `client_id` for that issuer is deleted so the next login registers again

### Requirement: OAuth device code flow
The client SHALL POST (form-encoded) to `device_authorization_endpoint` with the `client_id` and scope `urn:matrix:client:api:* urn:matrix:client:device:<device_id>`. It SHALL validate `device_code`, `user_code` and an http(s) `verification_uri`, defaulting `expires_in` to 600 s and `interval` to 5 s, and show the URL and code (preferring an http(s) `verification_uri_complete`).

#### Scenario: Instructions with complete URI
- **WHEN** `verification_uri_complete` is present
- **THEN** the message reads `Open this URL and approve the login (code <code>):\n<url>\nThe login completes on its own once you approve it.`

#### Scenario: Instructions without complete URI
- **WHEN** only `verification_uri` is present
- **THEN** the message reads `Open <url> and enter the code <code>.\nThe login completes on its own once you approve it.`

### Requirement: Verification page prompt
On a local session (neither `SSH_CONNECTION` nor `SSH_TTY` set), the client SHALL ask `Verification page:` with `Open in browser` / `Not now`. Token polling MUST already be running when it asks, so the prompt never blocks the login.

#### Scenario: Remote session
- **WHEN** `SSH_CONNECTION` or `SSH_TTY` is set
- **THEN** no browser prompt is shown and only the instructions are displayed

#### Scenario: Approval while prompt is open
- **WHEN** the user approves on another device before answering the prompt
- **THEN** the login completes anyway

### Requirement: OAuth token polling
Polling SHALL POST `grant_type=device_code` to `token_endpoint` and send the next request only after the previous response arrives. `authorization_pending` waits `interval` seconds, `slow_down` adds 5 s to the interval, and transient errors (no status, 408, 429, 5xx) retry. `expired_token` or a passed deadline yields `The login code expired`, and `access_denied` yields `The login was denied`.

#### Scenario: Slow down
- **WHEN** the token endpoint answers `slow_down` with interval 5
- **THEN** the next poll is sent after 10 s

#### Scenario: Completion
- **WHEN** the token endpoint returns tokens
- **THEN** the session stores them with `refresh = {kind: "oauth", token_endpoint, client_id, revocation_endpoint}` and calls `GET /account/whoami` for the `user_id`
- **WHEN** whoami fails
- **THEN** the refresh token is revoked, the client is reset and the error is reported

### Requirement: SSO login with local listener
On a non-SSH session, SSO SHALL listen on `127.0.0.1` with a random port and a random secret path, accepting requests only for that path. It SHALL open `<hs>/_matrix/client/v3/login/sso/redirect?redirectUrl=<encoded http://127.0.0.1:<port>/<secret>>`. Once it receives `loginToken`, it SHALL answer with a success HTML page that mentions Emacs and `POST /login` with type `m.login.token`. Request headers MUST be capped at 8 KB.

#### Scenario: Browser cannot open
- **WHEN** opening the browser fails
- **THEN** `Could not open the browser (<err>). Open this URL to log in:\n<url>` is shown and the listener keeps waiting

#### Scenario: Request without token
- **WHEN** the listener receives a request on the secret path without `loginToken`
- **THEN** it answers with HTML `This request did not contain a login token.`

#### Scenario: Timeout falls back to manual
- **WHEN** no login arrives within 120 s
- **THEN** `Did not receive the login from the browser` is shown and manual mode starts

### Requirement: SSO manual mode
Manual SSO (SSH sessions or after a timeout) SHALL use redirect URL `http://127.0.0.1/`, show the instructions to copy the redirected URL, and prompt `Paste the redirected URL or login token: `. It accepts either a URL that contains `loginToken=` or a raw token.

#### Scenario: URL without token
- **WHEN** the pasted URL has no `loginToken` parameter
- **THEN** `The URL does not contain a login token` is shown

### Requirement: Login result
On failure the login SHALL show `Error logging in: <error>`. On success it SHALL show `Login successful as <user_id>`, save the session (if enabled), start sync and open the room list.

#### Scenario: Successful login
- **WHEN** any login method completes
- **THEN** sync starts and the room list opens
