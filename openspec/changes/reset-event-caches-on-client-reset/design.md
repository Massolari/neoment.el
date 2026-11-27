# Design

## Context

- `neoment-client-reset` (`neoment-client.el`) is the single point that replaces `neoment--client`. Login (`neoment-auth.el`), logout, session expiry (`neoment-auth-session-expired`), session restore (`neoment-storage-restore-session`) and a failed OAuth `whoami` (`neoment-oauth.el`) all go through it.
- `neoment-client.el` does not require `neoment-events.el`; the dependency runs the other way. The module already inverts this with function variables such as `neoment-client-fetch-display-name-function` and `neoment-client-room-changed-functions`, which `neoment-events.el` sets at load time.
- `neoment-events-reset-caches` already exists and clears both tables; it is only called from tests.
- The reply-fetch callback already checks `(eq client neoment--client)` before it touches the cache. The profile callback calls `remhash` *before* that check.

## Goals / Non-Goals

**Goals:**
- Clear the two event caches on every client reset without adding a `neoment-client` → `neoment-events` require.
- Keep late responses from an old client away from the new client's caches.

**Non-Goals:**
- Auditing or clearing other module state (see proposal, out of scope).
- Bounding cache size within one session.

## Decisions

### A reset hook in `neoment-client.el`

Add `(defvar neoment-client-reset-hook nil)` and `run-hooks` it at the end of `neoment-client-reset`, after the new client is installed. `neoment-events.el` does `(add-hook 'neoment-client-reset-hook #'neoment-events-reset-caches)` at top level, beside the existing `setq` of `neoment-client-fetch-display-name-function`.

- *Alternative: call `neoment-events-reset-caches` from logout and session expiry.* Rejected: it misses login, restore and the OAuth failure path, and every future reset site would have to remember it.
- *Alternative: a single function variable like `neoment-client-fetch-display-name-function`.* Rejected: a reset is a broadcast that other modules may later want to join (for example media downloads). A hook allows several listeners.
- *Alternative: store the caches in the `neoment-client` struct.* This would make them follow the client automatically. Rejected for this fix: it is a bigger refactor of `neoment-events.el` and the tests, for the same observable result.

Running the hook after `setq` means a listener sees the new client, and the run is harmless when `neoment-events` is not loaded (empty hook).

### Guard the profile callback's `remhash`

Move `(remhash user-id neoment-events--profile-requests)` inside `(when (eq client neoment--client) ...)`. After a reset, the table was already cleared, so a stale callback has nothing of its own to remove. Without the guard it could delete the new client's in-flight marker and allow a duplicate request. This is the "Late display-name response" scenario in the spec.

## Risks / Trade-offs

- [Tests that rebuild a client with `neoment-client-reset` now also clear the event caches] → That matches what the tests already do by hand. Tests that preload the reply cache must do so after the reset, which is already the case in `neoment-events-test`.
- [A failed fetch that is in flight during the reset leaves no marker] → Intended: the new client fetches again if it needs the name.
