# Proposal

## Why

Neoment is a Matrix client for Neovim (Lua). This repository (`neoment.el`) is meant to give Emacs users the same client: same features, same UI, same on-screen text. It is empty right now apart from the functional spec in `emacs-port.md`. This change turns that document into a contract we can check against, and into a phased plan for building an idiomatic Emacs Lisp package.

## What Changes

- New Emacs Lisp package `neoment` (Emacs 29.1+, works in GUI and `emacs -nw`), built from scratch. There is no existing code, so nothing breaks.
- Login by OAuth 2.0 device code (preferred), password, or SSO, with `.well-known` homeserver discovery. The session is saved to disk and restored. Tokens refresh automatically through a single-flight queue. Logout.
- Continuous `/sync` long-poll loop with retries. Events are processed into an in-memory model: dedup, pending edits/redactions/reactions, threads, replies, membership text, receipts.
- Read-only UI buffers with major modes for:
  - the room list (sections, folding, badges, previews, fold state saved to disk)
  - the room/thread timeline (fixed 31-column gutter, date separators, "New messages" marker, rich replies, reactions, inline images, typing, tombstone)
  - spaces (`/hierarchy`)
  - room info
  - push-rule notification settings
- A compose buffer with markdown highlighting, `@` mention completion, and reply, edit, thread and attachment modes. Markdown→HTML conversion when sending, HTML→markdown when displaying.
- Message actions: react (emoji/text toggle), redact, edit, forward, go to replied message, threads, set read marker, view raw event, n/p navigation, load history.
- Media: authenticated download (token sent only in a header, only to the homeserver, only `mxc://`), open/save attachments, upload, clipboard images, hover popups for reactions and emoticons, image zoom.
- Room membership: join by id/alias, create or reuse a DM, accept/reject invites, leave, and handle being removed by others.
- Desktop notifications driven by the user's Matrix push rules, with per-platform handlers. Locally configured per-category levels (the original's `custom` source) are not ported.
- User options (`defcustom`), theme-aware faces, interactive commands with stable names, optional `transient` support, and ERT tests that port the original test cases.
- Out of scope, as in the original: E2EE, voice/video calls, profile editing, creating rooms other than DMs, moderation, editing room settings.

## Capabilities

### New Capabilities

- `matrix-auth`: homeserver discovery, choosing a login method, password / OAuth device code / SSO login, and cancelling a login attempt by generation.
- `session-management`: saving and restoring the session and cache on disk, token refresh (single-flight, soft logout, adopting a token rotated by another instance), session expiry, logout, and clearing the cache.
- `matrix-sync`: the `/sync` long-poll loop, its status, retries, processing order, and handling of invited/joined/left rooms, global account data and presence.
- `matrix-events`: how each Matrix event type updates the room/message model, plus derived rules (room name, unread state, ordering, display names, effective ids).
- `room-membership`: join (id, alias, DM), invite accept/reject, leave, and acknowledging removal by others.
- `rooms-list`: the side-window room list (layout, sections, ordering, badges, previews, folding), its actions, and the room pickers.
- `room-timeline`: the room and thread buffers (opening, tracking, timeline rendering, history pagination, flicker-free re-render, automatic read marking, hover popups).
- `message-actions`: commands on the message under the cursor (react, redact, edit, reply, forward, threads, go to replied message, read marker, raw event view, navigation, leave).
- `message-compose`: the compose buffer and the outgoing message protocol (text, reply, thread, edit, attachment, mentions, transaction ids).
- `markdown-conversion`: the lightweight markdown→HTML converter for sending and the HTML→markdown converter for display.
- `media-attachments`: authenticated media download and caching, inline images and zoom, opening/saving attachments, upload, and clipboard images.
- `spaces`: the space hierarchy buffer and joining rooms from it.
- `room-info`: the room information buffer (type, topic, space, status toggles, links, members, avatar).
- `notification-settings`: the global and per-room push-rule settings windows, and the rules for reading and writing them.
- `desktop-notifications`: deciding when to send desktop notifications (from the server's push-rule counts), how to word them, and the default handler on each platform.
- `client-configuration`: user options and their validation, faces (bubble borders recomputed when the theme changes), the main command and subcommands, keymap conventions, the `[Neoment]` message prefix, and optional transient integration.

### Modified Capabilities

None. The project has no existing specs.

## Impact

- New code: about 20 `neoment-*.el` files at the repository root (layout in design.md), ERT tests under `test/`, a package README, and a `Makefile`/Eldev-style test runner.
- Dependencies: Emacs 29.1+ only. `plz` is optional and preferred for async HTTP over curl when installed (otherwise `url.el` is used), and `posframe` is optional for popups (with a fallback). `mpv`, `xclip`/`wl-paste`/`pngpaste`/`osascript` are optional external tools.
- Disk: `<user-emacs-directory>/neoment/` (`data.json` mode 0600, `ui_state.json`, `oauth_clients.json`) and a cache directory (`cache.json`, `media/`).
- Network: Matrix Client-Server API v3/v1 endpoints and OAuth 2.0 endpoints (registration, device authorization, token, revocation) on the user's homeserver/issuer.
- Reference material: `emacs-port.md` is the detailed functional reference for every requirement here. It points to the original Lua source (`lua/neoment/**`), which is **not** in this repository; see design.md.
