# Design

## Context

Link text in room and thread buffers (both use `neoment-room-mode`) carries `neoment-link` = URL, plus `help-echo` = URL, except for spoilers, which carry `neoment-spoiler` = t. Emoticons also carry `neoment-emoticon`. `neoment-media.el` already runs a buffer-local `post-command-hook` in every room buffer. It schedules `neoment-media--show-popup` after `neoment-media-popup-delay` (0.5 s) idle at point. That function asks `neoment-media-popup-text` for text and shows it in a posframe, or with `message` when there is no GUI/posframe. Today it returns nil on links, so nothing happens. See proposal.md for why.

## Goals / Non-Goals

**Goals:**
- One idle mechanism for everything at point: reactions, emoticons and links.
- The URL in the echo area, identical in GUI and terminal frames.

**Non-Goals:**
- Changing the mouse `help-echo` tooltip.
- Shortening or prettifying long URLs. The echo area shows the raw destination.
- Showing anything for spoilers or bare (non-markdown) URLs. Bare URLs are not links in the renderer today.

## Decisions

**Reuse the existing idle hover timer.** In `neoment-media--show-popup`, when `neoment-media-popup-text` returns nil, look up the link text for point's properties. A new pure helper, `neoment-media-link-echo-text (props)`, returns the `neoment-link` value unless `neoment-spoiler` or `neoment-emoticon` is set, and nil otherwise. If the helper returns text, show it with `message` and don't touch posframe.
- Alternative: set `help-at-pt-display-when-idle`. It is a global user option, it shows every `help-echo` (also the image help), and it fights the user's own settings.
- Alternative: an `eldoc-documentation-functions` backend. It would need `eldoc-mode` in a `special-mode` buffer, and it adds a second idle timer with a different delay next to the popup timer.

**Precedence: reaction/emoticon popup first, then link.** An emoticon is a link to `mxc://`, and its popup is more useful than the raw URL. Checking the popup text first keeps the existing behaviour unchanged.

**Echo area only, not logged.** Bind `message-log-max` to nil around the `message` call, so that moving across links doesn't fill `*Messages*`. Skip the display when the minibuffer is active (`active-minibuffer-window`), so a prompt isn't overwritten. Don't clear the echo area when point moves. Emacs clears it on the next command anyway, and an explicit `(message nil)` could erase another package's message.

**Spoiler safety by property, not by content.** The helper checks `neoment-spoiler`, so a spoiler can't leak through this path even though its `neoment-link` holds the hidden text.

## Risks / Trade-offs

- [The echo area competes with other messages (sync errors, notifications)] → It only shows after 0.5 s idle on a link, and is replaced by any later message. Not logging it keeps `*Messages*` clean.
- [Very long URLs wrap or resize the echo area] → Same as Emacs's own `help-echo` in the echo area. Acceptable; truncation can be added later without spec changes.
- [Behaviour depends on point position after redisplay; invisible markers are adjacent to link text] → The text properties cover the whole link including the hidden `[`/`](url)`, and point can't rest inside invisible text, so any reachable link position yields the URL.
