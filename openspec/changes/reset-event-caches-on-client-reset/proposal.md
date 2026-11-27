# Proposal

## Why

The reply-preview cache and the profile-request tracker in `neoment-events.el` are global hash tables that nothing outside the tests ever clears (issue #23). After a logout, a session expiry or a switch to another account, reply previews in a room id the two accounts share come from the previous account's cache, which can show content the new account may not be allowed to see. Both tables also grow for the whole Emacs session.

## What Changes

- Every client reset (login, logout, session expiry, session restore, failed OAuth login) clears the cached reply previews and the profile requests marked as in flight.
- A reply or profile response that the previous client asked for, and that arrives after the reset, does not write to or remove anything from the new client's caches. Today the profile callback clears its in-flight marker before it checks the client, so a late response can remove the marker of a request the new client just started (issue #55).
- Out of scope: other module-level state (`neoment-notify--*`, which already follows its own client; `neoment-media--downloads`; render caches such as `neoment-room--code-cache` that hold no account data).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-management`: adds a requirement that per-account in-memory caches are cleared whenever the client is reset, and that late responses from the previous client do not touch them.

## Impact

- `neoment-client.el`: a reset hook, run by `neoment-client-reset`.
- `neoment-events.el`: registers `neoment-events-reset-caches` on that hook, and moves the profile callback's `remhash` behind its client check.
- Tests in `test/neoment-auth-test.el` / `test/neoment-events-test.el`.
- No API, dependency, or saved-file format changes.
