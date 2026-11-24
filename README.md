# Neoment for Emacs

A Matrix client for Emacs, ported from [Neoment](https://github.com/Massolari/neoment) for
Neovim. It has the same features, layouts and messages: a room list in a side window, room
and thread timelines, a markdown compose buffer, reactions, threads, media, spaces, room
information and notification settings.

Requires Emacs 29.1 or newer and works both in GUI frames and in `emacs -nw` (inline images
and graphical popups only appear in GUI frames).

## Installation

Neoment needs nothing beyond Emacs. Two packages are optional:

- [`plz`](https://elpa.gnu.org/packages/plz.html) (GNU ELPA) sends requests with `curl`, which
  handles the 30-second sync long-polls more reliably than the built-in `url.el`. When it is
  installed, Neoment uses it automatically (see `neoment-http-backend`).
- [`posframe`](https://elpa.gnu.org/packages/posframe.html) shows hover popups.

```elisp
(use-package neoment
  :vc (:url "https://github.com/Massolari/neoment.el")
  :commands (neoment neoment-command neoment-menu))
```

Optional external tools: `mpv` (audio playback, controlled from Emacs; see below), `pngpaste` or `osascript` (macOS clipboard
images), `xclip` or `wl-paste` (Linux clipboard images).

## Quick start

1. `M-x neoment`
2. Enter your Matrix ID (`@you:example.org`), a server name (`example.org`) or a homeserver
   URL (`https://matrix.example.org`).
3. Neoment discovers the homeserver and picks a login method: OAuth device code (preferred),
   password, or Single Sign-On.
4. The room list opens on the left once the first sync completes. Press `RET` on a room.

The session is saved and restored the next time you run `M-x neoment`.

## Commands

| Command | Description |
| --- | --- |
| `neoment` | Log in, or toggle the room list when logged in |
| `neoment-command` | Run a subcommand chosen with completion |
| `neoment-menu` | Transient menu of the commands below |
| `neoment-join` | Join a room id or alias, or open/create a DM with a user id |
| `neoment-logout` | Log out and delete the saved session |
| `neoment-pick-room` | Pick a room and open it |
| `neoment-pick-open-room` | Pick one of the rooms open in buffers |
| `neoment-sync-start` | Start the sync loop |
| `neoment-sync-stop` | Stop the sync loop |
| `neoment-quit` | Stop sync, timers and processes, kill all Neoment buffers and keep the session |
| `neoment-reload-config` | Validate the options again |
| `neoment-clear-cache` | Delete the room cache |
| `neoment-toggle-rooms-list` | Show or hide the room list |
| `neoment-notification-settings` | Global notification settings |

## Keys

Every buffer is read-only and uses single letters. Every key calls a named command you can
rebind with `keymap-set`, and `?` shows the bindings of the mode.

### Room list (`neoment-rooms-mode-map`)

| Key | Command |
| --- | --- |
| `RET` | `neoment-rooms-enter` (open, or answer an invite) |
| `TAB` | `neoment-rooms-toggle-fold` |
| `n` / `p` | `neoment-rooms-next` / `neoment-rooms-previous` |
| `a` | `neoment-rooms-toggle-favorite` |
| `l` | `neoment-rooms-toggle-low-priority` |
| `d` | `neoment-rooms-toggle-direct` (local only) |
| `r` | `neoment-rooms-toggle-read` |
| `s` | `neoment-rooms-change-status` |
| `u` | `neoment-rooms-refresh-room-state` |
| `i` | `neoment-rooms-show-room-info` |
| `N` | `neoment-rooms-room-notification-settings` |
| `M-n` | `neoment-notification-settings` |
| `f` / `F` | `neoment-pick-room` / `neoment-pick-open-room` |
| `q` | `neoment-toggle-rooms-list` |
| `Q` | `neoment-rooms-quit` (asks, then runs `neoment-quit`) |

### Room and thread buffers (`neoment-room-mode-map`)

| Key | Command |
| --- | --- |
| `RET` | `neoment-room-compose` |
| `r` | `neoment-room-reply` |
| `e` | `neoment-room-edit` |
| `t` | `neoment-room-open-thread` |
| `n` / `p` | `neoment-room-next-message` / `neoment-room-previous-message` |
| `a` / `A` | `neoment-room-react-emoji` / `neoment-room-react-text` |
| `d` | `neoment-room-redact` |
| `w` | `neoment-room-forward` |
| `R` | `neoment-room-goto-replied` |
| `m` | `neoment-room-set-read-marker` |
| `V` | `neoment-room-show-event` |
| `P` | `neoment-room-load-previous` |
| `L` | `neoment-room-leave` |
| `o` / `s` | `neoment-room-open-attachment` (open the link, attachment or emoticon at point; on a spoiler, show its content) / `neoment-room-save-attachment` |
| `u` / `U` | `neoment-room-upload` / `neoment-room-upload-clipboard-image` |
| `z` | `neoment-room-toggle-image-zoom` (on a message header line) |
| `O` | `neoment-player-menu` |
| `i` | `neoment-room-show-info` |
| `N` | `neoment-room-notification-settings` |
| `f` / `F` / `l` | room pickers and `neoment-toggle-rooms-list` |
| `q` / `g` | `neoment-room-quit` / `revert-buffer` |

### Audio player (`*neoment-player*`)

Opening an audio attachment with `o` plays it with `mpv` (Windows and systems without `mpv`
use the system program) and shows a one-line state buffer, for example
`▶ voice.ogg  0:42 / 1:15  1.5x  vol 80`. The buffer is read-only and, while
`neoment-player-forward-keys` is non-nil, sends every unmodified key to `mpv`, so its own
bindings and your `input.conf` work: `SPC` pause, `<left>`/`<right>` seek, `[`/`]` speed,
`m` mute, `9`/`0` volume, and so on. `C-` and `M-` chords keep their Emacs meaning, and `q`
stops the player and closes the window. Bindings that need a video window have no effect.
With the option set to nil only `SPC`, `<left>`, `<right>`, `[`, `]`, `=` and `q` are bound.

From a room buffer, `O` opens `neoment-player-menu` (pause, seek, speed, stop) without
leaving the room. Seek and speed steps are `neoment-player-seek-step` and
`neoment-player-speed-step`.

### Inline images (`neoment-media-image-map`)

In GUI frames, an image (or a video or location thumbnail) shows on its own line below the
message header. The cursor can move onto that line with `C-n` / `C-p`. The line belongs to its
message, so `r`, `e`, `a`, `s` and the other message keys work there, and it is left out of
copied text. Re-renders keep the cursor on the image and keep each image's size while the
buffer lives. With the cursor on the image line, these keys apply (every other key falls
through to the room keys):

| Key | Command |
| --- | --- |
| `z` | `neoment-room-toggle-image-zoom` (20% ↔ 100% of the window height; a resized image goes back to 20%) |
| `+` / `-` | `neoment-room-image-enlarge` / `neoment-room-image-shrink` (×1.25 / ÷1.25, between 5% and 100% of the window height) |
| `o` | `neoment-room-image-open` (full image in `*neoment-image: <file>*` in `image-mode`; video and location thumbnails open as attachments) |

### Compose buffer (`neoment-compose-mode-map`)

| Key | Command |
| --- | --- |
| `C-c C-c` | `neoment-compose-send-and-close` |
| `C-c C-k` | `neoment-compose-cancel` |

Type `@` and use `completion-at-point` (`C-M-i`) to mention room members.

### Spaces (`neoment-space-mode-map`) and room information (`neoment-room-info-mode-map`)

| Key | Space buffer | Room information |
| --- | --- | --- |
| `RET` | `neoment-space-enter` | |
| `TAB` | | `neoment-room-info-toggle-members` |
| `a` / `l` / `d` | | `neoment-room-info-toggle-favorite` / `neoment-room-info-toggle-low-priority` / `neoment-room-info-toggle-direct` |
| `o` / `z` | | `neoment-room-info-open-avatar` / `neoment-room-info-toggle-avatar-zoom` |
| `q` | `neoment-space-quit` | `neoment-room-info-quit` |
| `g` | `revert-buffer` | `revert-buffer` |

### Evil

No evil bindings are shipped. Configure the states yourself, for example:

```elisp
(with-eval-after-load 'evil
  (dolist (mode '(neoment-rooms-mode neoment-room-mode neoment-space-mode
                  neoment-room-info-mode))
    (evil-set-initial-state mode 'emacs)))
```

## Options

All options are in the `neoment` customization group (`M-x customize-group RET neoment`).

| Option | Default | Description |
| --- | --- | --- |
| `neoment-save-session` | `t` | Save the session and the room cache to disk |
| `neoment-login-method` | `nil` | `nil` (automatic), `oauth_device`, `password` or `sso` |
| `neoment-http-backend` | `auto` | `auto` (`plz` when installed, else `url.el`), `plz` or `url` |
| `neoment-notifier` | `neoment-notify-default-notifier` | Function `(msg level)` showing messages |
| `neoment-desktop-notifications-enabled` | `t` | Send desktop notifications |
| `neoment-desktop-notifications-handler` | `neoment-notify-default-desktop-handler` | Function `(title content)` |
| `neoment-room-picker-function` | `neoment-completing-read-picker` | Function `(items callback prompt)` |
| `neoment-open-room-picker-function` | `neoment-completing-read-picker` | Same, for open rooms |
| `neoment-on-open-attachment-function` | `neoment-media-default-open-handler` | Function `(path attachment)` |
| `neoment-player-seek-step` | `10` | Seconds the player seeks back or forward |
| `neoment-player-speed-step` | `0.25` | Speed change of the player's faster/slower commands |
| `neoment-player-mpv-arguments` | `nil` | Extra `mpv` arguments, e.g. `("--volume=70")` |
| `neoment-player-forward-keys` | `t` | Forward keys typed in the player buffer to `mpv` |
| `neoment-room-hide-markup` | `t` | Hide markdown markers and link URLs in room buffers (`nil` shows them dimmed) |
| `neoment-rooms-display-last-message` | `message` | `no`, `message`, `sender_message`, `sender_message_inline` |
| `neoment-rooms-room-title-format` | `room_space` | `space_room`, `room` or `room_space` |
| `neoment-icons` | Nerd Font glyphs | Alist of icons, see below |
| `neoment-icon-font-family` | `"Symbols Nerd Font Mono"` | Font for icon glyphs in GUI frames, `nil` to disable |

Desktop notifications follow your Matrix push rules (set them with
`neoment-notification-settings`). They are never sent during the first sync, for your own
messages, or for the room you are looking at while Emacs has focus.

## Icons and fonts

The default icons are [Nerd Font](https://www.nerdfonts.com/) glyphs. In GUI frames Neoment
routes them to the family in `neoment-icon-font-family` (default `Symbols Nerd Font Mono`),
when it is installed, so they render even if your default font is not a Nerd Font. The font
is appended to the default fontset, so fonts you set for those characters keep priority. Set
the option to `nil` to disable this.

Bubble edges use U+E0B6/U+E0B4; in GUI frames where no font has them, Neoment uses `▐`/`▌`
instead. Default icons that still cannot be displayed fall back to their plain counterparts;
icons you set yourself are never replaced. To use plain icons everywhere:

```elisp
(setq neoment-icons neoment-plain-icons)
```

## Files

- `~/.emacs.d/neoment/data.json`: session credentials (mode 0600)
- `~/.emacs.d/neoment/ui_state.json`: fold state of the room list
- `~/.emacs.d/neoment/oauth_clients.json`: OAuth client ids (kept on logout)
- `~/.emacs.d/neoment/cache/cache.json` and `cache/media/`: room cache and downloads

## Troubleshooting

- **Sync errors or stalls without `plz`**: install `plz`, or set `neoment-http-backend` to
  `plz` once it is installed. The `url.el` backend aborts a request after its timeout and
  retries, but curl is more robust on flaky networks.
- **Login method not offered**: unset `neoment-login-method` to let Neoment choose.
- **Session expired**: run `M-x neoment` again to log in.
- **Squares instead of icons**: install `Symbols Nerd Font Mono` (or set
  `neoment-icon-font-family` to an installed Nerd Font), or use
  `(setq neoment-icons neoment-plain-icons)`.
- **Stale room list**: `M-x neoment-clear-cache`, then restart the sync.
- **No clipboard images on Linux**: install `xclip` (X11) or `wl-clipboard` (Wayland).

## Not supported

As in the original: end-to-end encryption (encrypted rooms are not readable), voice and video
calls, profile editing, creating rooms other than direct messages, moderation (kick, ban) and
editing room settings.

## Development

```sh
make deps     # install plz (for its backend tests) and package-lint into .deps/
make test     # run the ERT suite
make compile  # byte-compile with warnings as errors
make lint     # checkdoc and package-lint
```
