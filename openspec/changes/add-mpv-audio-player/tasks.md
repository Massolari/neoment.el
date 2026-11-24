# Tasks

## 1. IPC core and options

- [x] 1.1 Add `neoment-player-seek-step`, `neoment-player-speed-step`, `neoment-player-mpv-arguments` and `neoment-player-forward-keys` `defcustom`s to `neoment-config.el`; verify `make compile` has no warnings.
- [x] 1.2 Spike with a real mpv before building on it: start `mpv --no-terminal --no-video --input-ipc-server=<sock> <file>`, send `["keypress","]"]` and `["keypress","m"]` over the socket, and verify `speed` and `mute` change. If they do not, stop and revisit decision 6b (drop forwarding, keep dedicated commands).
- [x] 1.3 Create `neoment-player.el` with the state holder, mpv start, the retrying socket connect, line-buffered JSON filter and `observe_property` setup for `pause`, `time-pos`, `duration`, `speed`, `volume`, `mute`; verify with ERT against a fake local-socket server (no real mpv) that property updates reach the state and a partial JSON line is buffered until complete.
- [x] 1.4 Implement lifecycle: sentinel (remove socket, clear state, `Playback finished` on EOF), `neoment-player-stop`, `kill-emacs-hook`, and the `Could not start mpv` error path; verify with ERT that the socket file is removed and the error message is shown when the socket never appears.

## 2. Controls, key forwarding and display

- [x] 2.1 Implement `neoment-player-toggle-pause`, `-seek-backward`, `-seek-forward`, `-speed-up`, `-speed-down`, `-speed-reset` with the `No audio playing` guard and speed clamped to 0.25; verify with ERT that the fake server receives the expected JSON commands (`cycle pause`, `seek ±N relative`, `set_property speed`).
- [x] 2.2 Implement `neoment-player--key-name` and `neoment-player-forward-key`; verify with an ERT table test: `?a`→`a`, `?]`→`]`, `?\s`→`SPACE`, `RET`→`ENTER`, `TAB`→`TAB`, `DEL`→`BS`, `<left>`→`LEFT`, `<prior>`→`PGUP`, `<next>`→`PGDWN`, `<f5>`→`F5`, `C-x`/`M-x`→nil, and that the fake server receives `["keypress", name]`.
- [x] 2.3 Implement the `*neoment-player*` buffer (mode without parent keymap, forwarding bindings only when `neoment-player-forward-keys` is non-nil, dedicated bindings `SPC`/`<left>`/`<right>`/`[`/`]`/`=` otherwise, `q` always stops and closes, `m:ss` rendering, speed only when not 1.0, volume and `muted`) and `neoment-player-play` replacing any existing player; verify with ERT that `0:42 / 1:15`, `1.5x`, `vol 80` and `muted` render, that `C-x` is unbound in the map, that `q` stops, and that a second play stops the first.
- [x] 2.4 Add the `neoment-player-menu` transient with `:transient t` suffixes; verify with an ERT check that it is a command and each suffix calls the matching command.

## 3. Integration

- [x] 3.1 Switch `neoment-media-default-open-handler` to `neoment-player-play` when `mpv` exists and `system-type` is not `windows-nt`, keeping the system-open fallback; update the existing test in `test/neoment-media-test.el` (old assertion on the `mpv` command line) and verify `make test` passes.
- [x] 3.2 Bind `O` to `neoment-player-menu` in `neoment-room-mode-map`, require `neoment-player` from `neoment.el`; verify with an ERT keymap check.
- [x] 3.3 Update `README.md` (key table row for `O`, player buffer key forwarding and `neoment-player-forward-keys`, `mpv` note) and verify the documented keys match the keymaps.
- [x] 3.4 Manual check with real mpv: play an audio, then pause, seek both ways, change speed with `[`/`]`, mute with `m`, change volume with `9`/`0`, stop with `q`, and quit Emacs while playing; verify no `mpv` process remains (`pgrep mpv`) and no `neoment-mpv-*` socket is left in the temp dir. Run `make all` (compile, lint, test) clean.
