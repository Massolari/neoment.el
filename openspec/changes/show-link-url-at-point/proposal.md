# Proposal

## Why

The markdown rendering change hid link URLs and put them in the link's `help-echo`. Emacs only shows `help-echo` when the **mouse** hovers the text: as a GUI tooltip, or in the echo area only when `tooltip-mode` is off. With the cursor on a link, nothing shows the URL. Checked on `main`: the rendered timeline still carries `help-echo` = URL on the link text, and the idle hover handler returns nothing for links. So the URL "in the echo area" only appeared in the mouse/no-tooltip setup, and reading links with the keyboard gives no way to see where they go.

## What Changes

- When the cursor rests on a link in a room or thread buffer, after the usual hover delay (about 0.5 s), the echo area shows the link's URL. This works the same in GUI and terminal frames.
- The URL is always shown in the echo area, never in the posframe popup. Links are text, and the echo area is where Emacs shows "where does this go".
- Spoiler links show nothing, so the spoiler isn't revealed. `o` still reveals it.
- Mention links (`matrix.to` user URLs) and `img:` emoticons keep their current behaviour. Mentions show their URL like any link. Emoticons keep their title/image popup.
- The mouse tooltip (`help-echo`) stays.

Assumption: "displaying the URL in the echo area" means seeing it when the cursor rests on the link, not only on mouse hover. No code change is needed for the mouse case.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `room-timeline`: adds a "Link URL at point" requirement. Resting the cursor on a non-spoiler link shows its URL in the echo area. "Hover popups" (reactions, emoticons) is unchanged.

## Impact

- `neoment-media.el`: the idle hover handler (`neoment-media-popup-text` / `neoment-media--show-popup`) learns about the `neoment-link` and `neoment-spoiler` text properties.
- `test/neoment-media-test.el`: new tests for link, spoiler and emoticon-link cases.
- No new dependencies, options or key bindings.
