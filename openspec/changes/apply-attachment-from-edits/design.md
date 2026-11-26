## Context

`neoment-events--handle-message` applies an edit by copying `body` and `formatted_body` from `m.new_content` into the target message. Attachments are only built in `neoment-events-event-to-message`, from the top-level `content` of an event (`neoment-events--attachment content type`, with the type looked up in `neoment-events-attachment-types`). Edits therefore never change `neoment-message-attachment`. The bridge's replacement event happens to repeat `msgtype`, `url` and `filename` at the top level, but `info` is only inside `m.new_content`, and the edit branch never reads either.

All three edit paths (live, pending, embedded) go through the same `m.replace` branch via `neoment-events-handle`, so one change covers them.

## Goals / Non-Goals

**Goals:**
- A message edited into an image/video/audio/file/location shows its bubble.
- Only validated, applied edits change the attachment.

**Non-Goals:**
- Removing an attachment through an edit, changing the validation rules, or fixing the bridge's body encoding.

## Decisions

- **Build the attachment from `m.new_content`**, since the Matrix spec makes it the authoritative content of the edit. In the edit branch, compute the type from `new-content`'s `msgtype` via `neoment-events-attachment-types` and, when it has a `url` (or `geo_uri` for locations), call `neoment-events--attachment new-content type`. Reuse avoids a second code path for thumbnails, durations and so on. The `neoment-events-event-to-message` condition `(and type (alist-get 'url content))` is mirrored in a small helper shared by both places.
  - Alternative: read the replacement event's top-level fields. Rejected: top-level content of an edit is a fallback and `info` is not guaranteed there.
- **Set the attachment inside the existing `(new-content ...)` clause**, after all validation clauses, so ignored edits cannot touch it. Only set when an attachment was built; a text edit leaves the old one (edits cannot legitimately drop media, and clearing risks hiding it on partial bridges).
- **Locations** have no `url`, only a `geo_uri`. The shared helper treats a location as having an attachment when `geo_uri` is present, and every other type when `url` is present. Because `neoment-events-event-to-message` uses the same helper, a regular `m.location` message now also gets its location attachment; before, it was dropped because the check only looked at `url`. This is decided: fix it for regular messages too.

## Risks / Trade-offs

- A displayed message changes from text-only to a bubble after the edit, so any cached rendering must be refreshed. The room buffer already re-renders edited messages, so no extra work is expected; verify when running the app.
- `body` for an attachment is also its caption/filename; the existing bubble rendering decides how it is shown (`neoment-room--attachment-bubble`), so no rendering change is needed.
