## Why

Pressing `o` on an audio message starts `mpv` as a plain `make-process` whose output goes to a read-only `*neoment-mpv*` buffer. This was ported from Neovim, where a `:terminal` buffer forwards keystrokes to mpv. An Emacs process buffer does not forward keys, so mpv's own keybindings (pause, seek, speed) are unreachable and the user can only listen from start to finish, or kill it. The goal is to listen to audio inside Emacs with real player controls (play/pause, seek back/forward, faster/slower), keeping mpv as the engine.

## What Changes

- Replace the fire-and-forget `mpv` process with a **controlled mpv**: start it with `--no-terminal --no-video --input-ipc-server=<socket>` and talk to it over mpv's JSON IPC (unix socket via `make-network-process :family 'local`). This is how Emacs packages such as `mpv.el`, EMMS's mpv backend and `empv` do it, instead of trying to embed a terminal.
- Add a `neoment-player` module that owns one player at a time (opening another audio replaces the current one), observes `pause`, `time-pos`, `duration` and `speed`, and exposes commands: toggle pause, seek back/forward by `neoment-player-seek-step` seconds, speed up/down, reset speed, stop.
- Show playback state (`▶ 0:42 / 1:15  1.5x  vol 80`, `⏸` when paused, `muted`) in a small read-only `*neoment-player*` buffer (replacing the 3-line mpv output window). With no video there is no mpv OSD, so `volume` and `mute` are observed and shown too.
- **Forward every unmodified key** typed in that buffer to mpv through the IPC `keypress` command (printable characters, arrows, `RET`, `TAB`, `DEL`, `Home`/`End`, `PgUp`/`PgDn`, `F1`–`F12`, translated to mpv key names). mpv's own bindings, including the user's `input.conf`, therefore work as in a native mpv window. `C-`/`M-` chords stay with Emacs, and `q` stays Emacs-side to stop the player and close the window. Controlled by the new `neoment-player-forward-keys` option (default `t`).
- Add a `neoment-player-menu` transient with the same controls, opened from the room buffer with `O`, so the user can control playback without leaving the room.
- Clean up when mpv exits, when the player is stopped, and on `kill-emacs` (kill the process, delete the socket file).
- Fall back to the system program when `mpv` is missing or IPC is unavailable (Windows, whose named pipes `make-network-process` cannot reach).
- New user options: `neoment-player-seek-step` (10), `neoment-player-speed-step` (0.25), `neoment-player-mpv-arguments`, `neoment-player-forward-keys` (`t`).

Out of scope: playlists/queue, video and window-dependent mpv bindings (fullscreen, stats overlay, OSD), a global mode-line indicator, Windows named-pipe support, forwarding modified (`C-`/`M-`) keys.

## Capabilities

### New Capabilities
- `audio-player`: in-Emacs control of an mpv audio process (start, pause/resume, seek, speed, stop, state display, lifecycle and cleanup).

### Modified Capabilities
- `media-attachments`: the "Default open handler" requirement changes — audio starts the controlled player instead of a 3-line mpv output window.
- `message-actions`: the room mode key bindings gain `O` for the player menu.

## Impact

- Code: new `neoment-player.el`; `neoment-media.el` (`neoment-media-default-open-handler`); `neoment-room.el` (keymap); `neoment-config.el` (new `defcustom`s); `neoment.el` (require).
- Tests: `test/neoment-media-test.el` asserts the old mpv command line and must change; new `test/neoment-player-test.el` using a fake IPC server, no real mpv.
- Docs: `README.md` (key table, `mpv` note).
- Dependencies: none new (`json` is built in; `transient` is already required).
