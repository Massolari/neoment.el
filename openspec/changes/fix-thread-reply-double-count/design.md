# Design

## Context

See proposal.md (Why). Relevant current behavior:

- `neoment-events-event-to-message` sets `thread-replies-count` from `unsigned.m.relations.m.thread.count` when that aggregation is present.
- `neoment-events--handle-message` (generic branch) does `(1+ count)` on the loaded root for every message with a `thread-root-id`, with no regard to `is-history` or to where the root came from.
- Every message enters through `neoment-events-handle-multiple`. It runs once per room timeline per sync (`neoment-sync.el`), once per history page (`neoment-room.el`, `is-history` t), and once per state refresh. It sorts the batch by `origin_server_ts` and recurses into pending events through the same function.
- `neoment-events-handle` already skips an event whose id is in `neoment-room-events`, so in a tracked room a reply that is delivered again is never handled twice.

The server's aggregation is a snapshot taken when the server sent the root. Any reply delivered in the same response (sync batch or `/messages` page) existed at that moment and is already counted. A reply from a later sync response is newer than the snapshot.

## Goals / Non-Goals

**Goals:**
- No reply is counted both by the server aggregation and by a local increment.
- Live replies to a root that is already displayed still bump its bubble right away.

**Non-Goals:**
- Recomputing counts on redaction of a thread reply (the server count is not adjusted today either).
- Correcting counts already persisted by `neoment-storage.el`. They are rebuilt from the server's aggregation when the root is next loaded.
- Fetching `/relations` to get an exact count.

## Decisions

### Increment only for live replies whose root was loaded in an earlier batch

`neoment-events-handle-multiple` binds a dynamic variable (e.g. `neoment-events--batch-ids`, a hash set). It is bound only by the outermost call, so recursive calls for pending events share it. `neoment-events--handle-message` adds each message id it stores to that set. The increment then runs only when:

- `is-history` is nil, and
- the root id is not in the current batch set.

When no batch is bound, as with a direct `neoment-events-handle` call such as the nested `unsigned.m.replace` case, the root necessarily came from an earlier batch, so the increment applies.

Alternatives considered:

- **Live-only (`is-history` nil) alone**, the issue's first suggestion. It fixes history pages but not live batches that hold both the root and its replies: the initial sync, a `limited` (gappy) sync, or a sync after a reconnect. These are common, so rejected.
- **Compare the reply's ts with the root's snapshot time** (`root ts + unsigned.age`). It depends on clock agreement between the homeserver and remote senders' `origin_server_ts`, which federation does not guarantee. Rejected as fragile.
- **Keep a set of seen reply ids per root.** The server count does not say which ids it covers, so a set cannot tell an already-counted reply from a new one when both arrive after the root. It only guards against redelivery, which `neoment-events-handle` already handles for tracked rooms. Rejected as more state for no gain.

### History never increments

A history page is one `/messages` response. Its roots carry an aggregation that covers every reply in the page and in newer pages. Replies loaded from newer pages earlier were added while the root was absent, so they never incremented either. This falls out of the `is-history` check, with no extra state.

## Risks / Trade-offs

- [A sync response is handled while a history page that contains the root is in flight. The page's snapshot can then include a reply that the sync already delivered or will deliver.] → The reply is handled once (event-id dedup). If it came first, the root was absent and nothing was incremented. If it comes after the page, it is in `neoment-room-events` and skipped. Only a reply sent between the two server snapshots and delivered by sync after the page could be off by one. This is rare, and the next load of the root resets the count.
- [Untracked rooms do not keep raw events, so redelivery is not deduplicated there.] → Untracked rooms keep only their last message, and the room bubble is shown only in tracked room buffers. Behavior there is unchanged from today.
