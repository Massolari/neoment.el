# Tasks

## 1. Reset hook

- [x] 1.1 In `neoment-client.el`, add `neoment-client-reset-hook` (defvar with docstring) and `run-hooks` it at the end of `neoment-client-reset`, after `neoment--client` is set. Then add a test in `test/neoment-auth-test.el` that binds the hook to a recorder, calls `neoment-client-reset`, and asserts the listener ran once and saw the new client. Verify with `make test`.

## 2. Event caches follow the client

- [x] 2.1 In `neoment-events.el`, register `neoment-events-reset-caches` on `neoment-client-reset-hook` at top level, next to the `setq` of `neoment-client-fetch-display-name-function`. Add a test in `test/neoment-events-test.el`: handle a reply so `!r:s $orig` is cached, call `neoment-client-reset`, handle the same reply again, and assert a second `/event/%24orig` request is issued and the reply is a placeholder ("Reply preview after switching accounts"). Verify with `make test`.
- [x] 2.2 Add a test that installs a logged-in client with a cached reply, calls `neoment-auth-session-expired` (with sync and storage stubbed as the existing auth tests do), and asserts the reply cache is empty ("Session expiry clears replies"). Verify with `make test`.
- [x] 2.3 Add a test that starts a reply fetch, resets the client, handles the same reply again so the new client has its own in-flight entry for `!r:s $orig`, then calls the old request's callback with an error and with a valid event, and asserts the new entry is still in the cache, unchanged, and its placeholder is still unfilled ("Late reply response from the previous client"). It passes because of the existing client check; check that it fails when that check is removed. Verify with `make test`.
- [x] 2.4 In `neoment-events-fetch-display-name`, move `(remhash user-id neoment-events--profile-requests)` inside the `(eq client neoment--client)` check. Add a test: start a fetch for `@u:s`, reset, start a new fetch for `@u:s`, fire the old callback, then call `neoment-events-fetch-display-name` again and assert only two profile requests were made in total ("Late display-name response does not drop a new fetch"). Check that the test fails before the change and passes after. Verify with `make test`.

## 3. Integration checks

- [x] 3.1 Run `make compile` (byte-compile with warnings as errors) and `make lint`, and confirm both are clean.
- [x] 3.2 Run `openspec validate reset-event-caches-on-client-reset --strict` and confirm it passes.

## Workflow follow-up

- Reference issues #23 and #55 in the PR so merging it closes both.
- Archive the change after merge and sync the `session-management` spec.
