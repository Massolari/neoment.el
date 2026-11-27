# Proposal

## Why

Thread roots show more replies than they have (issue #14). A root's `thread-replies-count` starts from the server's aggregated `unsigned["m.relations"]["m.thread"].count`. That count already includes every reply that existed when the server sent the root. `neoment-events--handle-message` then adds 1 for every reply it handles while the root is loaded. Batches are sorted by timestamp, so the root always comes before its replies. Every reply in the same sync batch or history page is therefore counted twice: a root with `count 2` plus its two replies in one batch shows `↳ 4 replies` instead of 2.

## What Changes

- A thread reply adds 1 to its loaded root's count only when the root's server count cannot include it: the root was not stored, with a server count, in the batch that delivered the reply.
- Replies in paginated history therefore never change a root's server count: the root is in the same page or not loaded yet.
- A root without a server count (a homeserver that omits the aggregation) keeps counting its loaded replies locally.
- The `Threads` requirement and its "count 2 + new reply → 3" scenario are made explicit about this: the scenario covers only a live reply to a root loaded earlier. New scenarios cover a root and its replies in the same batch, and in a history page.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `matrix-events`: the `Threads` requirement now says when a reply increments its root's count (root loaded in an earlier batch, or without a server count) and when it does not (same batch as a root with a server count).

## Impact

- `neoment-events.el`: `neoment-events--handle-message` (increment condition) and `neoment-events-handle-multiple` (tracks the ids of roots loaded in the current batch).
- `test/neoment-events-test.el`: the existing `neoment-events-threads` test, plus new regression tests for the same-batch and history cases.
- No change to storage, rendering (`neoment-room.el` bubble), or the API surface.
