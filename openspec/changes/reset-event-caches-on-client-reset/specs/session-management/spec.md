# Spec Delta

## ADDED Requirements

### Requirement: Per-account caches cleared on client reset
Whenever the client is reset (login, logout, session expiry, session restore, or a failed login), the client SHALL forget all cached replied messages and all display-name fetches it marked as in flight. A reply or display-name response requested by the previous client that arrives after the reset MUST NOT add, change or remove any entry of the new client's caches.

#### Scenario: Reply preview after switching accounts
- **GIVEN** account A loaded the replied event `$e` in room `!r:s` and its preview is cached
- **WHEN** the user logs out, logs in as account B, and B receives a reply to `$e` in `!r:s`
- **THEN** the replied event is fetched again with B's session, and the reply shows a placeholder until that fetch returns

#### Scenario: Session expiry clears replies
- **WHEN** the session expires while reply previews are cached
- **THEN** no reply preview remains cached after the reset

#### Scenario: Late reply response from the previous client
- **WHEN** a replied-event fetch started before a reset returns after it
- **THEN** the reply cache of the new client is unchanged

#### Scenario: Late display-name response does not drop a new fetch
- **GIVEN** the previous client started fetching the display name of `@u:s`, then the client was reset, and the new client started its own fetch for `@u:s`
- **WHEN** the previous client's response arrives
- **THEN** the new client's fetch is still marked in flight, and no second fetch for `@u:s` starts while it is pending
