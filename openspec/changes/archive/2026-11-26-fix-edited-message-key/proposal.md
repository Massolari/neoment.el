# Proposal

## Why

Issue #18: after an edit, a message's `id` becomes the edit's event id, while its key in the room's message table should stay the original event id. Three places put a message back into the table under `neoment-message-id`, so an edited message ends up stored under the **edit's** id:

- closing a room buffer (`neoment-room-set-tracked` with nil) puts the last message back,
- an untracked room adding its newest message (`neoment-room-add-message`) uses the same key,
- the storage cache writes `messages` keyed by `neoment-message-id`, and loading trusts that key.

After closing the buffer or restarting Emacs, `(neoment-room-get-message room "$original")` returns nothing. Reactions, edits and redactions that later target the original id go to pending and are never applied. This was reproduced: message `$o`, edit `$oe`, `set-tracked nil` → message keys are `("$oe")`, and a reaction to `$o` stays pending.

## What Changes

- A message is always stored under its **effective id** (`edit_data.id` when edited, otherwise `id`), the original event id. This applies everywhere a message is put into a room's message table: adding a message, closing a room buffer, and loading the cache.
- `cache.json` keys the cached last message by its effective id.
- Loading the cache keys each message by the effective id of the loaded message and ignores the stored key. Caches already written with the wrong key heal on the next start, with no migration step.
- Unchanged: an edit still sets the message's `id` to the edit event id and `edit_data.id` to the original. Dropping that rewrite would be a bigger change (it touches the spec, `show-event`, reply jumping and tests). It is out of scope here, and design.md explains why.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `matrix-events`: "Edits" says the message stays stored under the original id. "Room tracking" says the last message kept on close stays under its original id, so later relations to it still apply.
- `session-management`: adds a "Cached message key" requirement. The cached message is keyed by its effective id, and loading keys messages by effective id. "Compact room cache" itself is unchanged.

## Impact

- `neoment-client.el`: `neoment-room-add-message`, `neoment-room-set-tracked`.
- `neoment-storage.el`: `neoment-storage--room-to-json`, `neoment-storage--room-from-json`.
- Tests: `test/neoment-events-test.el` gets regression tests for close-then-react, the cache round-trip of an edited message, and loading a cache that has the old wrong key.
- No API, option or dependency changes. The `cache.json` format is unchanged apart from which id is used as the key.
