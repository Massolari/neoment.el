# Tasks

## 1. Apply attachments from edits

- [x] 1.1 In `neoment-events.el`, add a helper that returns the attachment plist for a content alist: look up the type from `msgtype` in `neoment-events-attachment-types`, require a non-empty `url` (or a `geo_uri` for `location`), and call `neoment-events--attachment`. Use it in `neoment-events-event-to-message` in place of its inline `(and type (alist-get 'url content) ...)` and verify that `make test` still passes. Add an ERT test that a regular `m.location` message with `geo_uri` `geo:1.5,2.5` and no `url` gets a location attachment with url `https://maps.google.com/?q=1.5,2.5`.
- [x] 1.2 In the `(new-content ...)` clause of the `m.replace` branch of `neoment-events--handle-message`, set `neoment-message-attachment` of the target to the helper's result for `new-content` when it is non-nil; leave it untouched otherwise. Verify with a new ERT test `neoment-events-edit-adds-video`: `m.notice` `$n` from `@alice:s` edited by `@alice:s` with a video `m.new_content` (`url` `mxc://s/vid`, `info` with duration 12000, size 2726771, `w` 480, `h` 864, mimetype `video/mp4`) → `(plist-get (neoment-message-attachment msg) :type)` is `video`, with the expected `:duration`, `:size` and `:mimetype`, and the content is the edit's body.
- [x] 1.3 Add ERT tests for the pending case (edit first, then the notice) and the embedded case (`unsigned.m.relations.m.replace` on the original event), both ending with the video attachment. Modeled on `neoment-events-edits` in `test/neoment-events-test.el`.
- [x] 1.4 Add ERT tests that an image message edited with plain text keeps its attachment, that a text message edited into an `m.location` gets the location attachment, and that an edit from `@mallory:s` (and one targeting a redacted message) with a video `m.new_content` leaves the attachment nil/unchanged.

## 2. Integration check

- [ ] 2.1 Run the full `make` (compile with warnings as errors, lint, test) and verify it is green.
- [ ] 2.2 Check the real flow with the event from the report: a `m.notice` "Decrypting message from WhatsApp failed…" with the bundled `m.video` replacement shows the video bubble in the room buffer.

## Workflow follow-up

- Archive the change after review; it adds "Edits carry attachments" to `openspec/specs/matrix-events/spec.md`.
