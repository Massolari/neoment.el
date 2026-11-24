# Design

## Context

`neoment-media-default-open-handler` runs `mpv --no-video <file>` through `make-process` with output in `*neoment-mpv*`. Emacs process buffers do not forward keystrokes to the child (unlike Neovim's `:terminal`), so mpv's controls are unreachable. See proposal.md.

Constraints: the package targets macOS/Linux primarily, already requires `transient`, keeps one module per concern (`neoment-media.el`, `neoment-notify.el`, ...), and tests run without network or external programs.

## Goals / Non-Goals

**Goals:**
- Real player controls from Emacs, with mpv as the engine and no new package dependency.
- Controls reachable both from a dedicated player buffer and from the room buffer.
- No leaked processes or socket files.

**Non-Goals:**
- Playlists, video, a mode-line segment, Windows named pipes.
- A generic mpv client library; only the few commands and properties the player needs.

## Decisions

**1. Drive mpv through its JSON IPC, not a terminal.**
Start `mpv --no-input-terminal --no-video --msg-level=all=error --no-msg-color --input-ipc-server=<sock> --pause=no <file>`, then connect with `make-network-process :family 'local :service <sock>`. Commands are newline-terminated JSON (`{"command":["cycle","pause"]}`); mpv replies and emits events as JSON lines.
*Why:* this is the established Emacs approach (`mpv.el`, EMMS `emms-player-mpv`, `empv`). Alternatives: (a) `term`/`vterm` buffer — works, but it is a 3-line terminal that needs `char-mode`, steals keys from the room buffer and `vterm` is an external module; (b) `comint` stdin — mpv reads keys from a tty, not lines; (c) depend on `mpv.el` — adds a dependency for a tiny feature and its API surface is larger than needed.

**2. Own the socket path and wait for it.**
Socket: `ipc` inside a private directory from `(make-temp-file "neoment-mpv-" t)` (mode 0700, removed on cleanup), since mpv's IPC accepts `run` and the socket must not be reachable by others. mpv creates the socket asynchronously, so connect from a short timer that retries (every 0.05 s, up to ~5 s; a refused connection is retried, since the socket file can exist before mpv listens) and reports `Could not start mpv` with mpv's error output on timeout or early exit.

**3. Observe properties instead of polling.**
After connecting send `observe_property` for `pause`, `time-pos`, `duration`, `speed`, `volume` and `mute` (volume and mute are shown because `--no-video` leaves no OSD to give feedback). The process filter accumulates partial lines, parses complete ones with `json-parse-string` (`:object-type 'plist`, `:false-object nil`), updates a state struct and re-renders the player buffer. Events with `"event":"end-file"` and `reason` `eof` mark natural completion.

**4. Single player, state in one module.**
`neoment-player.el` holds a global `neoment-player--state` (mpv process, IPC connection, socket path, file name, pause, position, duration, speed). `neoment-player-play` stops any existing player first. Commands are thin wrappers over `neoment-player--command`, which signals `No audio playing` when the connection is gone.
*Why:* a queue or multiple players add UI and lifecycle surface that the user did not ask for.

**5. Relative seeking and clamped speed.**
Seek with `["seek", ±step, "relative"]` (mpv clamps at 0 and EOF). Speed changes use `["add","speed",±step]` so rapid presses accumulate; only a step that would go below 0.25 (judged from the observed speed) is sent as an absolute `set_property`. Reset sets 1.0.

**6. Two control surfaces.**
`*neoment-player*` (a `special-mode` derivative, 1–2 lines, shown with the same `display-buffer-below-selected` action as today) forwards keys to mpv (decision 6b), and `neoment-player-menu` is a `transient-define-prefix` reachable via `O` from the room buffer, calling the dedicated commands from decision 5. A transient suffix keeps the prefix open after a command (`:transient t`) so the user can press seek repeatedly. Full forwarding is limited to the player buffer: in the room buffer keys such as `n`/`p` belong to the room.

**6b. Forward keys with mpv's `keypress` command.**
`neoment-player-forward-key` is bound in the player map to every printable character (a loop over `32..126` plus non-ASCII self-insert via `[remap self-insert-command]`) and to the special keys `<left>`, `<right>`, `<up>`, `<down>`, `RET`, `TAB`, `DEL`, `<home>`, `<end>`, `<prior>`, `<next>`, `<f1>`–`<f12>`. It reads `last-command-event` and `neoment-player--key-name` maps it to mpv's name (printable char → itself, `?\s` → `SPACE`, `RET` → `ENTER`, `TAB` → `TAB`, `DEL` → `BS`, `<left>` → `LEFT`, `<prior>` → `PGUP`, `<next>` → `PGDWN`, `<f5>` → `F5`, …) and sends `["keypress", name]`. Events with modifiers map to nil and are not bound, so `C-x`, `M-x`, `C-g` keep their Emacs meaning. Only `q` is deliberately left out: it stops the player and closes the window so the buffer is cleaned up (forwarded it would only make mpv quit). The player map has no parent keymap, so `special-mode` keys such as `g` or `n` do not shadow forwarded keys. The whole forwarding layer is installed only while `neoment-player-forward-keys` is non-nil; when nil the map has just the dedicated bindings.
*Why:* it reuses mpv's own bindings and the user's `input.conf` with no per-command wrappers. *Alternatives:* (a) hard-code a list of commands — the original plan, less capable and needs maintenance; (b) a terminal buffer — rejected in decision 1.
*Unverified assumption:* that `keypress` triggers the default bindings with `--no-video`. It goes through mpv's core input layer so it should, but the first implementation task verifies it against a real mpv before the rest builds on it. Window-dependent bindings (fullscreen, stats overlay, OSD) will be no-ops; `s` writes a screenshot.

**7. Lifecycle.**
The mpv sentinel removes the socket file, deletes the connection, clears state and (if the file ended naturally) shows `Playback finished`. A `kill-emacs-hook` entry calls stop. `neoment-player-stop` kills the mpv process (not just the connection) so nothing outlives the player.

**8. Fallback.**
`neoment-media-default-open-handler` calls the player only when `(executable-find "mpv")` and `system-type` is not `windows-nt`; otherwise it keeps the system-open path. The handler stays swappable through `neoment-on-open-attachment-function`.

**9. User options** live in `neoment-config.el` next to the other `defcustom`s: `neoment-player-seek-step`, `neoment-player-speed-step`, `neoment-player-mpv-arguments` (extra arguments appended to the mpv command line, e.g. `("--volume=70")`), `neoment-player-forward-keys` (default `t`, see decision 6b).

## Risks / Trade-offs

- [Socket not ready or mpv dies at startup] → bounded retry loop, sentinel check, error message including the process output.
- [Stale socket file after a crash] → file is removed in the sentinel and a fresh unique name is used for each start.
- [Fast-moving `time-pos` events re-render too often] → mpv emits it about every 0.1–1 s while playing; render only the player buffer and only when the displayed second changes.
- [mpv option/property names change between versions] → only long-stable names are used (`pause`, `time-pos`, `duration`, `speed`, `seek`, `observe_property`).
- [`keypress` does not fire default bindings without a window/terminal] → verified first (task 1.2); if it fails, fall back to the dedicated commands only and drop forwarding.
- [Forwarded key has a side effect, e.g. `s` screenshot, or a user `input.conf` runs a script] → expected: forwarding mirrors a native mpv window, and `neoment-player-forward-keys` turns it off.
- [Windows unsupported] → explicit fallback to the system program.
- [Tests cannot run mpv] → the IPC layer is tested against a fake local-socket server created with `make-network-process :server t` in the test; the process start is stubbed.

## Open Questions

- Whether to add a mode-line indicator later (not needed to meet the goal).
