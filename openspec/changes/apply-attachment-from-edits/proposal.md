## Why

The WhatsApp bridge first sends an undecryptable-message notice (`msgtype: m.notice`, "Decrypting message from WhatsApp failed…") and then edits it (`m.replace`) into the real message, here an `m.video` with `url`, `filename` and `info` in `m.new_content`. Neoment applies only `body` and `formatted_body` from `m.new_content`, so the message ends up as plain text ("Já está guardado aqui 👊🏼") with no video bubble. Any edit that turns a message into media is affected the same way.

## What Changes

- When an applied `m.replace` edit's `m.new_content` describes an attachment (`msgtype` image, video, audio, file or location, plus its `url`/`info`), the target message gets that attachment, built the same way as for a regular message.
- This holds for all three paths that apply edits: live edit events, edits that wait for their target (pending), and edits embedded in `unsigned["m.relations"]["m.replace"]`.
- Regular `m.location` messages (which have `geo_uri` but no `url`) now get their location attachment too; before, they were dropped.
- Edits whose `m.new_content` is plain text leave an existing attachment unchanged.
- Out of scope: the literal octal escapes (`J\303\241…`) in the bridge's `body`, which are a bridge-side encoding problem; downloading or decrypting media; changing validation rules (same sender, not state, not redacted).

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `matrix-events`: edits now also replace the target's attachment when `m.new_content` carries one; location messages without a `url` get an attachment.

## Impact

- `neoment-events.el`: edit branch of `neoment-events--handle-message` (and its helpers).
- `test/neoment-events-test.el`: new ERT tests.
- `openspec/specs/matrix-events/spec.md` updated on archive.
