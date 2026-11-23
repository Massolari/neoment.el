# Tasks

Phases follow emacs-port.md §20. Each group ships its own ERT tests. `make test`, `make compile` (no warnings) and `make lint` must stay green at the end of every group.

## 1. Foundation (scaffolding, config, faces, HTTP, storage)

- [x] 1.1 Create `neoment.el` (package header, `Package-Requires: ((emacs "29.1") (plz "0.9"))`, autoload stubs) and empty module files per design D1; verify `make compile` byte-compiles every file.
- [x] 1.2 Add `Makefile` targets `deps`, `test`, `compile` (warnings as errors) and `lint` (checkdoc + package-lint), plus `test/test-helper.el`; verify `make deps test` runs and reports 0 tests.
- [x] 1.3 Implement `neoment-config.el`: `neoment` group, all defcustoms from emacs-port.md §4 (excluding the notification source and custom level options) with `choice` types and defaults, validation warnings, and `neoment-reload-config` (`Configuration reloaded`); verify with ERT tests for defaults and an invalid login method.
- [x] 1.4 Implement `neoment-notify--message` (`[Neoment] ` prefix, goes through `neoment-notifier` with a level); verify with an ERT test that a custom notifier receives the prefixed text and the level.
- [x] 1.5 Implement `neoment-faces.el`: every face from emacs-port.md §16, the 20 `neoment-user-N` faces, `neoment-icons` defaults (§4.1), bubble border faces computed from content/default backgrounds and recomputed via `enable-theme-functions`, and the bubble edge selection with its `▐`/`▌` fallback; verify with an ERT test that the border foreground equals the content background after `neoment-faces--update`, and one that stubs `char-displayable-p` and checks the fallback characters and their faces.
- [x] 1.6 Implement `neoment-http.el` on `plz`: `neoment-http-request` with JSON/form/binary bodies, connect/total timeouts, `(:ok DATA)`/`(:error ERR)` results, and parsing of Matrix errors (`status`, `errcode`, `error`, `soft_logout`) with transient classification (no status/408/429/5xx); verify with ERT tests that stub `plz` for success, Matrix error, and network failure.
- [x] 1.7 Implement `neoment-api-request` (homeserver-relative paths, `Authorization` only for `<homeserver>/` URLs, stale-client guard per D4) with a refresh hook point left for group 11; verify ERT tests for the header-scoping and stale-drop rules of session-management "Access token confidentiality" / "Stale responses discarded".
- [x] 1.8 Implement `neoment-storage.el`: data/cache dirs, JSON read/write helpers (false versus empty-array round-trip), `data.json` written under mode 0600, `ui_state.json`, `oauth_clients.json`, and the media dir; verify with ERT tests in a temp `user-emacs-directory` that check the file mode and round-trip values.

## 2. Password login and session

- [ ] 2.1 Implement Matrix ID/server input parsing (`@user:server`, bare server, http(s) URL, empty, invalid) in `neoment-auth.el`; verify with the ERT cases from matrix-auth "Matrix ID or server input".
- [ ] 2.2 Implement `.well-known` discovery with 5 s/10 s timeouts that never fail, plus the client reset that keeps `device_id`; verify with mocked-HTTP ERT tests for a valid base_url, a 404, and a non-http value.
- [ ] 2.3 Implement parallel login-method detection and selection (configured method, oauth preferred silently, single method, `completing-read` with the three labels, every error message); verify with mocked ERT tests for each scenario in matrix-auth "Login method detection" and "Login method selection".
- [ ] 2.4 Implement the login generation counter and cancellation hooks (SSO listener close / OAuth poll cancel stubs); verify with an ERT test that a callback from an older generation changes nothing.
- [ ] 2.5 Implement password login (`Username: `/`Password: ` prompts, request body, token/expiry/user_id handling, `well_known` homeserver switch) and the login result messages; verify with a mocked ERT login flow that ends in `Login successful as …`.
- [ ] 2.6 Implement session save (respecting `neoment-save-session`) and restore (7-day rule without a refresh token, `Matrix session restored for …`); verify with ERT tests for fresh, stale-without-refresh, and stale-with-refresh sessions.
- [ ] 2.7 Implement `neoment-logout` (confirmation, `/logout`, file deletion that keeps `oauth_clients.json`, messages) and `neoment-clear-cache`; verify with mocked ERT tests for confirm, cancel, server error, and the cache present/absent messages.
- [ ] 2.8 Wire the `M-x neoment` entry point (restore, else prompt; toggle the list when logged in) and verify manually against a local Synapse that login works and that restarting Emacs restores the session.

## 3. Sync, model and events

- [ ] 3.1 Implement the structs and derived rules in `neoment-client.el` (display name, space name, is-space, room's space, membership, unread rule, message ordering, last activity, effective id); verify with ERT tests for each rule in matrix-events "Derived room rules", "Unread rule", and "Ordering and last activity".
- [ ] 3.2 Implement event dispatch with dedup, batch ordering, and pending processing in `neoment-events.el`, covering room account data/state events and canonical alias state messages; verify with ERT tests for duplicates, a reaction before its target, a tombstone default, and alias removal text.
- [ ] 3.3 Implement message parsing (body/formatted rules, `m.new_content`, redacted-by text, mentions, attachments with download URLs, location and thumbnails, threads and the root counter); verify with ERT fixture-event tests per attachment type and per thread case.
- [ ] 3.4 Implement edits (newer-only, id swap, embedded `unsigned` edits) and redactions (pending, edit removal, `[Redacted: reason]`, reaction-key cleanup) and reactions; verify with the ERT scenarios from matrix-events "Edits", "Redactions", and "Reactions".
- [ ] 3.5 Implement the membership text table from emacs-port.md §8.2 and member add/remove; verify with one ERT test per row of the table.
- [ ] 3.6 Implement `m.receipt` handling (own user, main thread, highest ts, local replaced by server, ts-less move, fully_read fallback); verify with ERT receipt tests.
- [ ] 3.7 Implement async reply and display-name resolution with caches and a dirty-room re-render hook (design D9); verify with a mocked ERT test showing the placeholder first and then the filled reply after the stubbed fetch returns.
- [ ] 3.8 Implement room tracking (track/untrack, last-message-only retention); verify with ERT tests from matrix-events "Room tracking".
- [ ] 3.9 Implement the sync loop in `neoment-sync.el` (request params, single in-flight request, status, the retry policy with 3 messages, start/stop commands, processing order, invite/join/leave/account data/presence, heroes naming, unread-count trigger, save every 10 syncs, 45 s client timeout, `condition-case` around processing, `:noquery` processes, raised `gc-cons-threshold` while processing); verify with mocked ERT tests for each matrix-sync scenario, including the leave-dialog conditions, a timed-out request that retries, and a processing error after which the next sync still starts.
- [ ] 3.10 Implement compact `cache.json` save/load for rooms; verify with an ERT test that a room with 50 messages round-trips with one message and `is_tracked` false.

## 4. Rooms list

- [ ] 4.1 Implement the pure renderer for the header lines (title rule, presence bubble, sync status variants) and empty states; verify with ERT text comparisons for each status case and the 30-column title.
- [ ] 4.2 Implement section classification, ordering, and section headers with counts and the always/conditional sections; verify with ERT tests for the priority chain and unread-before-recent ordering.
- [ ] 4.3 Implement room lines (indent, icon, name format options, relative time incl. `dd/mm`, badges with faces, room-space suffix, line/icon faces) and the three last-message preview styles with truncation; verify with ERT text and property assertions against emacs-port.md §9.3.
- [ ] 4.4 Implement the spaces tree (recursive, joined children only, folded by default) and fold toggling with persistence in `ui_state.json`; verify with ERT tests for TAB on a section, TAB on a space, TAB elsewhere (error message), and state reloaded from disk.
- [ ] 4.5 Implement `neoment-rooms-mode`, the side window (D11 width, fixed and dedicated, `hl-line`), `neoment-toggle-rooms-list`, and opening rooms in the right-hand window; verify with an ERT test in batch that the toggle creates and deletes the side window, then check the split behaviour manually.
- [ ] 4.6 Implement list actions `a`/`l` (tag PUT/DELETE with messages), `d` (local direct), `r` (private receipt or marked_unread), `s` (presence prompt), `u` (state refresh), `n`/`p` navigation skipping preview lines, `N` room and `M-n` global notification settings, and the invite RET dialog; verify with mocked ERT tests for request payloads and messages, including the invite-specific errors, and ERT tests for the preview skip and the end-of-list message.
- [ ] 4.7 Implement the room pickers (item format, prompts, `No open rooms`, customisable functions); verify with an ERT test that formats the items and calls a stub picker function.

## 5. Read-only room buffer

- [ ] 5.1 Implement the timeline renderer as a pure function (gutter, name alignment/truncation, user colour cycle, date separators, body lines, state/redacted faces, `(edited)`, reply quote block, attachment bubbles with size/duration formatting, reactions line, thread indicator, mentions/emoticon faces, the New-messages marker rule, tombstone, typing); verify with ERT text comparisons of the emacs-port.md §10.2 example plus targeted property assertions.
- [ ] 5.2 Implement `neoment-room-mode`: buffer naming, `Loading...` initial content, `visual-line-mode`, the `wrap-prefix`, header line (room and thread), and the decoration copy filter; verify with an ERT test that `filter-buffer-substring` on a rendered line returns only the content.
- [ ] 5.3 Implement position-preserving re-render (design D7) and jump-to-end on the first page; verify with an ERT test that keeps point on the same message after a new message is inserted above or below it.
- [ ] 5.4 Implement history pagination (`/messages` params, `End`, auto-next on an empty chunk, messages) and opening behaviour (track, load, `joined_members`, re-render on arrival, untrack on kill); verify with mocked ERT tests.
- [ ] 5.5 Implement automatic read marking on buffer entry and visible updates (marked_unread false, read_markers with an optimistic local receipt); verify with mocked ERT tests and confirm manually that the list badge clears on entering a room.
- [ ] 5.6 Wire the sync to re-render only changed open rooms, coalesced through a short idle timer and skipping buffers not shown in any window (rendered when they become visible); verify with an ERT test that an unchanged open room's buffer is not touched (via a modification tick), that two syncs in a row cause one render, and that a hidden buffer renders when displayed.

## 6. Compose and send

- [ ] 6.1 Implement markdown→HTML (`neoment-markdown-to-html`) following the markdown-conversion spec; verify with an ERT suite covering code preservation, mentions, quotes, spoilers, links, emphasis, headings, lists and line breaks.
- [ ] 6.2 Implement HTML→markdown (`neoment-markdown-from-html`); verify with an ERT suite covering `mx-reply` removal, forwarded notice, spoilers, blockquotes, emoticons, `data-md`, code blocks with entities, and the final entity decoding.
- [ ] 6.3 Implement `neoment-compose-mode` (window below at height 10, buffer names for every mode plus the attachment suffix, markdown font-lock, edit prefill, focus restore and height on close, `C-c C-c`/`C-c C-k`); verify with an ERT test for buffer naming and edit prefill, and check the window behaviour manually.
- [ ] 6.4 Implement mention completion at point (members except self, case-insensitive id/name match, inserts the id with a name annotation); verify with an ERT test calling the capf function directly.
- [ ] 6.5 Implement the send payload builder (text, mentions linking only known names, reply, thread with fallback, edit wrapper, attachment msgtype by mimetype, `neoment-el-<uuid>` txn) and fully_read-on-success; verify with ERT payload assertions for each message-compose scenario, then check manually that Element shows a sent reply, edit, thread message and mention correctly.

## 7. Message actions

- [ ] 7.1 Implement message-at-point lookup and `n`/`p` navigation; verify with ERT tests on a rendered buffer, including skipping state lines and the end message.
- [ ] 7.2 Implement `RET`/`r`/`e`/`t` entry points (own-message check, thread buffer `neoment://thread/…` with `Loading thread...`, start-thread compose); verify with ERT tests for the messages and buffer names.
- [ ] 7.3 Implement reactions `a`/`A` with toggle-to-redact, plus `neoment-emoji.el` (design D14); verify with mocked ERT tests that a new reaction sends `m.reaction` and an existing one redacts.
- [ ] 7.4 Implement `d` redact, `m` set read marker, `w` forward (content plus reused mxc, then open the target), and `V` show event; verify with mocked ERT payload and message tests.
- [ ] 7.5 Implement `R` go-to-replied with mark push and the load-more prompts loop; verify with mocked ERT tests for found, found after one page, and history exhausted.
- [ ] 7.6 Implement `L` leave (confirm, success, "Not a known room" local removal, `M_FORBIDDEN` success) and `neoment-join` (DM reuse/create, already joined, join with `via`); verify with mocked ERT tests covering every room-membership scenario.
- [ ] 7.7 Bind the full `neoment-room-mode-map` per message-actions "Room mode key bindings"; verify with an ERT test that each key resolves to the named command.

## 8. Media

- [ ] 8.1 Implement `neoment-media.el`: authenticated download to the media dir, mxc-keyed image cache, and the mxc-only guard; verify with mocked ERT tests for the cache hit and for refusing a non-mxc URL.
- [ ] 8.2 Implement inline images (GUI only, column 31, width/height limits, dropped if the buffer re-renders first) and `z` zoom; verify manually in a GUI frame, and with an ERT test that TTY rendering shows only the bubble.
- [ ] 8.3 Implement `o` open (emoticon/reaction/message/location paths and messages) and the default handler (mpv 3-line window, otherwise system opener); verify with a mocked ERT test that the handler receives the right path and origin.
- [ ] 8.4 Implement `s` save with the overwrite prompt and the `name(N).ext` fallback; verify with ERT tests in a temp dir.
- [ ] 8.5 Implement `u` upload (mimetype detection via `mailcap` with a `file` fallback, `/upload` request, compose with the attachment) and `U` clipboard upload per platform with its error messages; verify with mocked ERT tests and manually check a clipboard paste on macOS/Linux.
- [ ] 8.6 Implement hover popups (idle timer, reaction label plus reactors, emoticon image, posframe with echo-area fallback, close on move); verify with an ERT test of the popup text builder and check posframe manually.

## 9. Spaces and room info

- [ ] 9.1 Implement `neoment-space.el` (buffer, hierarchy fetch and error, layout, `children_state` order without duplicates, `Joined` bubble, `(No Name)`, empty message); verify with ERT render tests from a fixture hierarchy.
- [ ] 9.2 Implement the space actions (join prompt with `via`, open space/room, `q`/`g`/`f`/`F`/`l`); verify with mocked ERT tests.
- [ ] 9.3 Implement `neoment-room-info.el` (layout, status toggles with key hints, links, collapsible sorted members, avatar 16×8 with zoom/open, invite restrictions); verify with ERT render tests and with mocked tag-toggle tests.

## 10. Push rules and desktop notifications

- [ ] 10.1 Implement push-rule level readers (global categories, per-room none/all/mentions/global, global label by member count or `is_direct`); verify with ERT tests ported from the push-rules cases.
- [ ] 10.2 Implement the write sequences (global: per existing rule, actions then enabled, stop on first error; per-room: create first, enable, delete obsolete, percent-encoded ids) and the reload with its error messages; verify with mocked ERT tests that assert the exact request sequence.
- [ ] 10.3 Implement the settings pop-up UI and the `neoment-notification-settings` command (titles, cursor on the current option, `RET`/`q`/`ESC`, `(Saving…)` guard); verify with an ERT render test and check manually.
- [ ] 10.4 Implement notification decisions: suppression rules, focus tracking, title/body, server source (candidates, count increase, fallbacks, reset on client change); verify with ERT tests for each desktop-notifications scenario.
- [ ] 10.5 Implement the default handlers (D-Bus with a one-time warning, `osascript` with argv, w32); verify with an ERT test that the macOS command line passes the texts as separate args, and trigger a real notification manually.

## 11. OAuth device code, SSO and token refresh

- [ ] 11.1 Implement OAuth client registration with the `oauth_clients.json` cache and `invalid_client` eviction; verify with mocked ERT tests.
- [ ] 11.2 Implement the device authorization request, validation, user instructions (both variants), and the SSH-aware `Verification page:` prompt issued after polling starts; verify with mocked ERT tests for both instruction texts and for the remote session.
- [ ] 11.3 Implement token polling (pending, slow_down +5 s, transient retry, expired/denied messages, deadline) and completion (oauth `refresh` record, whoami, revoke on failure); verify with mocked ERT tests that drive a fake clock/timer stub.
- [ ] 11.4 Implement the SSO local listener (random port and secret path, 8 KB cap, token/no-token HTML responses, 120 s timeout to manual) and manual mode (URL or raw token parsing); verify with ERT tests that connect to the real loopback listener from batch Emacs, and with parsing unit tests.
- [ ] 11.5 Implement `neoment-token.el`: proactive refresh under 60 s, the single-flight waiter queue with 30 s timeout, legacy versus OAuth refresh, keeping the old refresh token, saving after refresh; verify with mocked ERT tests that 3 concurrent requests trigger exactly one refresh.
- [ ] 11.6 Implement `M_UNKNOWN_TOKEN` handling (token-changed retry, soft-logout refresh+retry once), permanent-failure adoption from `data.json`, transient tolerance, and once-only session expiry; verify with mocked ERT tests for each session-management scenario.
- [ ] 11.7 Implement OAuth logout via RFC 7009 revocation when a `revocation_endpoint` exists; verify with a mocked ERT test of the form body.
- [ ] 11.8 Verify manually: an OAuth device-code login against a homeserver with MAS (or matrix.org) and an SSO login against a Synapse with an SSO provider, both complete and survive an Emacs restart.

## 12. Finishing

- [ ] 12.1 Add `neoment-command` (completing-read dispatcher) and an optional transient menu, and confirm `?` → `describe-mode` in every mode; verify with an ERT test that dispatching `logout` calls `neoment-logout`.
- [ ] 12.2 Write `README.md` (install, quick start, commands, keymaps per mode, every option, the Nerd Font note and a non-Nerd-Font icon preset, troubleshooting, out-of-scope list); verify that every documented command and option exists via an ERT test that walks the documented symbol list.
- [ ] 12.3 Run `make compile lint test` with zero warnings, zero checkdoc/package-lint errors and all tests passing.
- [ ] 12.4 Run an end-to-end smoke test in GUI and `emacs -nw` against a local Synapse: log in, browse the list, open a room, send/edit/reply/react/redact, upload, open a space and room info, change notification settings, receive a desktop notification, log out.
- [ ] 12.5 Check responsiveness: quit Emacs during a sync and confirm there is no process prompt, and profile the first sync on an account with many rooms (`profiler-start`); if typing freezes noticeably, add chunked processing (design Risks).

## Workflow follow-up

- Archive the change with `openspec archive port-neoment-to-emacs` once all groups are complete and reviewed.
