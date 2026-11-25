# Design

## Context

See proposal.md for why. Current state:

- `neoment-events--handle-message` (edit branch) changes the target in place. It sets `neoment-message-id` to the edit's event id and `edit_data` to `(:id <original> :timestamp ts)`, and does not re-key the table entry. Right after an edit, the table is correct.
- `neoment-message-effective-id` already returns `edit_data.id` or `id`, which is the original event id. Rendering (`neoment-message` text property), replies, reactions, redactions and media file names already use it.
- Three places later put a message into `neoment-room-messages` under `neoment-message-id`:
  - `neoment-room-add-message` (both the tracked and the untracked branch),
  - `neoment-room-set-tracked` (when closing),
  - `neoment-storage--room-to-json` (the cache key).
- `neoment-storage--room-from-json` puts each message under whatever key the JSON file has. Caches already written by the buggy code therefore load under the edit's id.
- `neoment-room-find-message` and `neoment-room--goto-message` also match by `neoment-message-id`, so lookups by the edit's id still work through them. They don't need to change.

## Goals / Non-Goals

**Goals:**
- One rule for the table key: it is always `neoment-message-effective-id`.
- Existing broken caches heal on load, with no migration step.

**Non-Goals:**
- Removing the `id := edit id` rewrite (see Decisions).
- Changing `neoment-message-id` as stored in the cached message body. It keeps the edit's id so that a restored message is the same as it was before saving.

## Decisions

**1. Key by `neoment-message-effective-id` at every place that puts a message into the table.**
Use it in `neoment-room-add-message` (both branches), `neoment-room-set-tracked`, `neoment-storage--room-to-json`, and `neoment-storage--room-from-json`. For a message that was never edited the effective id is the same as `id`, so nothing changes for unedited messages. `add-message` normally gets messages that haven't been edited yet, but using the same helper there keeps the rule in one place and closes the next version of this bug before it happens.
- *Alternative: snapshot the table entry in `set-tracked` (keep the key found by `maphash`) instead of recomputing it.* That fixes the close path only. The cache writer and loader would still need their own fix. Rejected because it gives two different mechanisms for one rule.

**2. The loader ignores the stored key and uses the effective id of the parsed message.**
Then the fix also covers caches written before it, and the key in the file is effectively derived data. The loader already has the parsed message, so this costs nothing.
- *Alternative: trust the key and rely on the fixed writer.* A broken cache would then stay broken until the next save, and that save would read the bad in-memory key. In practice the writer fix alone would repair it on the next save. Still, between load and save, relations sent during the first sync would go pending. Rejected.

**3. Keep the `id := edit event id` rewrite for now.**
The issue suggests asking whether the rewrite is worth keeping. Today nothing depends on `neoment-message-id` being the edit's id in a way users would notice. `show-event` tries the effective id first, and jumping to a replied message matches either id. Removing the rewrite would still mean changing the Edits requirement, the test that asserts `id = "$e2"`, and the fallbacks in `show-event` and `--goto-message`. Those fallbacks also cover placeholder and replied messages. That is a separate cleanup with its own risk. This change keeps the fix small and makes the key rule hold whatever happens to the rewrite later.

## Risks / Trade-offs

- [The same bug can come back through another `puthash` site added later] → The new spec text states the rule, and the regression tests cover close, save and load. A grep for `puthash (neoment-message-id` during review finds any new site.
- [The cache file keys and the message `id` field now differ for edited messages] → That is intended. The loader never trusts the key, so the two can't drift apart in a way that matters.

## Migration Plan

None needed. Old caches load correctly with Decision 2, and the next save writes the corrected key. Rolling back to the old code reads the new cache fine (the key is just a string).
