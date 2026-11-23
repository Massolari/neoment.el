# Design

## Context

- The repository has no code. The only input is `emacs-port.md`, a detailed functional description of the Neovim original (in Portuguese, with UI strings in English). The specs in this change are the contract. `emacs-port.md` is the detailed reference for exact strings, layouts and tables (membership actions, defcustom defaults, faces, icons).
- `emacs-port.md` refers to the original Lua sources (`lua/neoment/**`, `tests/*_spec.lua`) as "in this repository", but they are **not** here. When a detail is missing from both the specs and `emacs-port.md`, the upstream project (github.com/Massolari/neoment) is the fallback reference.
- Target: Emacs 29.1+, GUI and TTY. The code must byte-compile without warnings and pass `checkdoc` and `package-lint`.
- See proposal.md for motivation and scope.

## Goals / Non-Goals

**Goals:**
- Idiomatic Emacs Lisp: major modes derived from `special-mode`/`text-mode`, `defcustom`/`defface`, named interactive commands, `display-buffer` actions, no blocking I/O.
- Clear separation: protocol (HTTP/auth/token) → state (client model, events, sync) → UI (buffers/modes). This lets ERT test protocol and state without a display.
- The rendered text of the room list and timeline matches the documented layouts column for column.

**Non-Goals:**
- A line-by-line translation of the Lua code.
- E2EE, calls, or room administration (see proposal).
- A general Matrix SDK for other packages. The internal API is private (`neoment--` prefix) except for the documented commands and options.

## Decisions

### D1. Package layout: flat files at the repo root
One file per responsibility, following emacs-port.md §3: `neoment.el` (entry, autoloads, `Package-Requires`), `neoment-config.el`, `neoment-faces.el`, `neoment-http.el`, `neoment-auth.el`, `neoment-oauth.el`, `neoment-sso.el`, `neoment-token.el`, `neoment-client.el`, `neoment-events.el`, `neoment-sync.el`, `neoment-storage.el`, `neoment-markdown.el`, `neoment-notify.el`, `neoment-notification-settings.el`, `neoment-rooms.el`, `neoment-room.el`, `neoment-compose.el`, `neoment-media.el`, `neoment-space.el`, `neoment-room-info.el`, `neoment-emoji.el`. Tests go in `test/neoment-*-test.el`.
*Alternative*: a single big file, which is harder to test and review. A `lisp/` subdirectory is unusual for ELPA/MELPA single-package repos.

### D2. HTTP: `plz` (optional) or `url.el` behind a thin `neoment-http` wrapper
`neoment-http-request` (method, url, headers, body, timeouts, `:as` json/binary/file) is the **only** function that touches the network. It parses Matrix errors into a plist `(:status :errcode :error :soft-logout)` and calls back with `(:ok DATA)` / `(:error ERR)`. Authenticated calls go through `neoment-api-request`, which:
1. waits for the single-flight refresh when the token expires within 60 s;
2. adds `Authorization` only when the URL starts with `<homeserver>/`;
3. handles `M_UNKNOWN_TOKEN` (retry once if the token changed, refresh on soft logout, otherwise expire);
4. drops the callback when the client has been replaced (D4).

Tests stub `neoment-http-request` with `cl-letf`.
*Backends*: `neoment-http-request` has two backends, chosen by `neoment-http-backend` (`auto`, `plz` or `url`). `auto` (the default) uses `plz` when it is installed and `url-retrieve` otherwise, so the package needs no dependency beyond Emacs. `plz` is preferred because curl handles 30 s long-polls, connect timeouts and binary uploads reliably. The `url` backend adds what `url.el` lacks: a timer that aborts the request after its total timeout (the connect timeout is folded into the total), `set-process-query-on-exit-flag` nil on the connection, the response body saved to a file for downloads, and the same error plist, where connection failures have no status and so stay transient for the retry logic. `plz` is loaded with `(require 'plz nil t)` and is not in `Package-Requires`.
*Alternative*: requiring `plz`. It was the first choice, and was relaxed so that the package installs with no external dependency. The long-poll behaviour of the `url` backend must be checked against a real server.

### D3. Data model: `cl-defstruct` + hash tables
Structs `neoment-client`, `neoment-room`, `neoment-invited-room`, `neoment-message` and `neoment-attachment` follow emacs-port.md §7. Collections keyed by id (`rooms`, `messages`, `events`, `display-names`, `presence`) are `equal` hash tables. JSON is parsed with `json-parse-buffer :object-type 'alist :array-type 'list :null-object nil :false-object :false`. Raw events are kept as parsed alists (for `V` and the redaction/edit lookup). Storage serialises the reduced room form explicitly instead of dumping structs, so the file format stays the documented JSON.
*Alternative*: plists everywhere, which give weaker field access and no type checks.

### D4. Client identity and the generation counter
`neoment--client` holds the current struct. Every async callback captures the client (and, for login, `neoment--login-generation`) and returns early unless it is still `eq` to the current one. This single rule covers stale sync, refresh, push-rule and login responses (session-management "Stale responses discarded", matrix-auth "Login entry point").

### D5. Single-flight token refresh
`neoment-token` keeps `neoment--refresh-waiters`, a list of callbacks. The first caller starts the refresh (30 s timeout). Later callers append themselves. On completion every waiter receives the same result. If a permanent failure happens, the client reads `data.json` again before declaring the session expired. A one-shot `neoment--session-expired-p` flag makes sure the expiry message appears only once.

### D6. Sync loop as a process-driven chain
`neoment-sync--run` sends one request. Its callback processes the response (in the order matrix-sync specifies) and then schedules the next request with `run-at-time 0` (or 1 s after an error). A `neoment--sync-in-flight` flag rules out overlapping requests. Stopping clears the running flag and cancels the in-flight request process. Processing runs inside `condition-case`: an error is reported as a sync error and the next request is still scheduled, so the loop never dies silently. The request has a 45 s total timeout (curl `--max-time` with `plz`, a timer with `url.el`), so a connection that died during sleep or a network change becomes an ordinary error. Every network process is created with `:noquery`, so quitting Emacs never prompts about it. `gc-cons-threshold` is bound higher while a response is processed, so garbage collection does not run in the middle of a batch.
*Alternative*: timers polling a queue. That is more moving parts for no benefit.

### D7. Rendering: real text with properties, full re-render that keeps position
Timeline and room-list buffers are produced by pure functions: model in, propertised string out. These are easy to test with ERT (the "rendering" tests in emacs-port.md §19). Every character carries `neoment-message` (message id) or `neoment-room`/`neoment-section`. Gutters, separators, icons and bubbles carry `neoment-decoration t`. A buffer-local `filter-buffer-substring-function` removes decoration when copying. Continuation lines use the `wrap-prefix` property. The bubble edge characters are chosen once per render from the frame showing the buffer (Nerd Font glyphs, or `▐`/`▌` when a GUI frame cannot display them) and passed to the pure renderer, so tests cover both variants.
On re-render, the client records `(message-id . offset-within-message)` for point and for `window-start` in each window showing the buffer, replaces the whole buffer text inside `inhibit-read-only`, then restores both positions. This is simpler than the original's prefix/suffix diff and still meets "cursor never jumps". A diff can be added later if flicker shows up. Renders are coalesced: a sync marks buffers dirty, and a short idle timer (about 0.1 s) renders each dirty buffer once. Buffers that are not shown in any window are skipped and rendered when they become visible.
*Alternative*: overlays for virtual text. Rejected because they are heavy for long timelines and awkward to copy-filter.

### D8. Preview lines in the room list are real lines marked non-selectable
They carry `neoment-preview t` and no `neoment-room` property, so actions on them report "No room found…". `n`/`p` skip them by searching for the next line with a `neoment-room`, space or section property. `next-line`/`previous-line` keep their default behaviour.

### D9. Asynchronous replies and display names
Event processing never blocks. A reply first gets a placeholder `replying_to` (id only). The client fetches `GET /rooms/<r>/event/<id>` through a per-room in-flight cache, then fills the message in and marks the room dirty for re-render. Display names work the same way through a global `profile` cache. The renderer shows the user id until the name arrives.

### D10. Popups
An idle timer of 0.5 s, started from a buffer-local `post-command-hook`, reads text properties at point (`neoment-reaction`, `neoment-emoticon`). If `posframe` is installed and the frame is graphical, the client uses `posframe-show`. Otherwise it uses `message`. A `post-command-hook` hides the popup when point moves. `posframe` is a soft dependency (`(require 'posframe nil t)`).

### D11. Windows
- The room list uses `display-buffer-in-side-window` (`side left`, `slot 0`, `window-width` computed as `min 50 (floor (* 0.2 (frame-width)))`) with `window-size-fixed 'width` and `dedicated t`.
- Rooms open in the window to the right of the list (`window-in-direction 'right`), or in a new split if there is none.
- Compose uses `display-buffer-below-selected` with `window-height 10`, and `window-size-fixed 'height` is set in the compose buffer. Closing it calls `delete-window` and selects the room window.
- Room info and threads use `display-buffer-in-direction` right with `window-width 50`.

### D12. Storage
`neoment-storage` writes JSON with `json-serialize`. `data.json` is created inside `with-file-modes #o600`. Data lives in `(locate-user-emacs-file "neoment/")`. The cache directory is `neoment/cache/` under the same root, which keeps a single place to clean up.

### D13. Markdown converters are pure, regex-based functions
They follow the rules in the markdown-conversion spec, so they can be tested exhaustively. Code spans and blocks are pulled out into placeholders first, then the rest is processed and the placeholders are put back. This is the same strategy as the original. Compose highlighting uses a small set of `font-lock-keywords` (bold, italic, code, headings, links, quotes, mentions). It reuses `markdown-mode` faces when that package is loaded.

### D14. Emoji table
`neoment-emoji` builds the reaction list lazily from `ucs-names`, filtered to the emoji code blocks and to characters that are displayable. Labels look like `"😄 :grinning_face_with_smiling_eyes:"`. This avoids bundling a large generated table. Names follow Unicode instead of the original's GitHub shortcodes, which is an accepted cosmetic difference.

### D15. Desktop notifications and focus
Focus is tracked with `after-focus-change-function` and `frame-focus-state`. Handlers:
- Linux: `notifications-notify` (`require 'notifications`).
- macOS: `osascript` through `make-process` with `-e 'on run argv' … 'display notification (item 1 of argv) with title "Neoment" subtitle (item 2 of argv)'`, passing the texts as argv, never interpolated.
- Windows: `w32-notification-notify`.

### D16. Keymaps and optional integrations
Each mode has a `defvar-keymap` with the single-letter bindings from the specs, and `?` runs `describe-mode`. `neoment-command` uses `completing-read` over subcommand names. A `transient` menu is optional polish in the final phase. No evil-specific bindings are shipped. Evil users configure the state and keys themselves, for example through evil-collection.

### D17. Tests and tooling
A `Makefile` provides these targets:
- `make deps` installs `plz` (and `package-lint`) into `.deps/` via `package.el`.
- `make test` runs `emacs -Q --batch -L . -L test -l ert -l test/…` with `ert-run-tests-batch-and-exit`.
- `make compile` runs byte-compile with `byte-compile-error-on-warn`.
- `make lint` runs `checkdoc` and `package-lint`.

Each implementation phase brings its own tests. The original Busted test **cases** (markdown, membership text, receipts, push rules, login flow, token, logout, leave sync, notifications) are rebuilt from the specs, because the Lua tests are not available (see Context).

## Risks / Trade-offs

- [Original Lua source and tests are not in the repo] → Specs and `emacs-port.md` are authoritative. Consult upstream on GitHub only for edge cases neither covers, and record any new decision in the spec as part of that phase.
- [Full re-render of large timelines may be slow] → History is paginated at 20 events, untracked rooms keep 1 message, and only dirty open rooms re-render. If profiling shows a problem, switch to the prefix/suffix diff from the original.
- [Freeze while processing the first sync on accounts with many rooms] → The sync filter keeps the payload small and GC is deferred during processing. If profiling still shows a freeze, process rooms in chunks spread over `run-at-time 0` calls.
- [Nerd Font glyphs are missing in many setups] → Bubble edges fall back automatically to `▐`/`▌` in GUI frames. Other icons are customisable (`neoment-icons`); document a non-Nerd-Font preset in the README.
- [Column alignment with wide characters such as emoji and CJK in names] → Compute widths with `string-width` (TTY) or `string-pixel-width` when needed, and truncate with `truncate-string-to-width`.
- [`plz` behaviour on process errors and timeouts] → All of it stays inside `neoment-http`, which maps curl exit codes to transient errors (no status) for the retry logic.
- [`url.el` long-polls and timeouts are less reliable than curl] → `plz` stays the preferred backend under `auto`; the `url` backend enforces its own total timeout and its sync loop is verified manually against a real server.
- [Emacs 29 JSON functions treat `:false` and `nil` differently] → All JSON goes through one parse/serialise helper pair, with tests for false versus empty-array round-trips.
- [Clipboard and `mpv` helpers differ per OS] → Each lives behind a small function chosen per `system-type`, with clear error messages. Only Linux and macOS are manually verified; Windows is best effort.
- [SSO listener security] → The listener binds to `127.0.0.1` only, uses a random secret path, has an 8 KB header cap, closes after the first valid token or a 120 s timeout, and is closed when a new login starts.

## Migration Plan

This is greenfield, so nothing needs migrating. Users install the package and run `M-x neoment`. The session files use the same JSON shape as the original but live under the Emacs directory, so nothing is shared with a Neovim installation. To roll back, uninstall the package and delete `<user-emacs-directory>/neoment/`.

## Open Questions

- The OAuth `client_name`/`client_uri` values for registration (e.g. `"Neoment for Emacs"` plus the repo URL). These are cosmetic constants and can be set at implementation time.
- How to distribute the package (MELPA recipe or GNU ELPA) after the code is complete. This does not affect the build.
