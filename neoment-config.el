;;; neoment-config.el --- User options for Neoment  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Douglas M.

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The `neoment' customization group and every user option of the
;; package, plus their validation.

;;; Code:

(defgroup neoment nil
  "A Matrix client."
  :group 'comm
  :prefix "neoment-")

(defcustom neoment-save-session t
  "Whether the session and the room cache are saved to disk."
  :type 'boolean)

(defcustom neoment-login-method nil
  "Login method to use.
nil picks one automatically, preferring OAuth device code."
  :type '(choice (const :tag "Automatic" nil)
                 (const :tag "OAuth (device code)" oauth_device)
                 (const :tag "Password" password)
                 (const :tag "Single Sign-On (browser)" sso)))

(defcustom neoment-http-backend 'auto
  "How HTTP requests are sent.
`auto' uses the `plz' package (curl) when it is installed and the
built-in `url.el' otherwise.  `plz' and `url' force one of them."
  :type '(choice (const :tag "plz when installed, else url.el" auto)
                 (const :tag "plz (curl)" plz)
                 (const :tag "url.el" url)))

(defcustom neoment-notifier 'neoment-notify-default-notifier
  "Function that shows a message to the user.
It is called with the message (already prefixed with \"[Neoment] \")
and a level, one of the symbols `info', `warn' or `error'."
  :type 'function)

(defcustom neoment-desktop-notifications-enabled t
  "Whether desktop notifications are sent."
  :type 'boolean)

(defcustom neoment-desktop-notifications-handler
  'neoment-notify-default-desktop-handler
  "Function that shows a desktop notification.
It is called with the title and the content of the notification."
  :type 'function)

(defcustom neoment-room-picker-function 'neoment-completing-read-picker
  "Function used to pick a room.
It is called with ITEMS, a list of (LINE . ROOM-ID) pairs, CALLBACK,
a function called with the chosen ROOM-ID, and PROMPT."
  :type 'function)

(defcustom neoment-open-room-picker-function 'neoment-completing-read-picker
  "Function used to pick one of the rooms open in buffers.
It takes the same arguments as `neoment-room-picker-function'."
  :type 'function)

(defcustom neoment-on-open-attachment-function
  'neoment-media-default-open-handler
  "Function called to open a downloaded attachment.
It is called with the local PATH (or a URL for locations) and the
ATTACHMENT plist, whose `:origin' says where it came from."
  :type 'function)

(defcustom neoment-rooms-display-last-message 'message
  "How the room list shows the last message of each room."
  :type '(choice (const :tag "Do not show" no)
                 (const :tag "Message" message)
                 (const :tag "Sender, then message" sender_message)
                 (const :tag "Sender: message" sender_message_inline)))

(defcustom neoment-rooms-room-title-format 'room_space
  "How room names are shown in the room list."
  :type '(choice (const :tag "Space/Room" space_room)
                 (const :tag "Room" room)
                 (const :tag "Room, then space" room_space)))

(defconst neoment-default-icons
  '((invite . "")
    (buffer . "\U000F0BAB")
    (favorite . "")
    (people . "")
    (space . "\U000F0D16")
    (room . "\U000F0BA7")
    (low_priority . "\U000F0604")
    (reply . "↳")
    (right_arrow . "▶")
    (down_arrow . "▼")
    (down_arrow_circle . "")
    (bell . "\U000F0D5B")
    (dot . "•")
    (dot_circle . "")
    (vertical_bar . "│")
    (vertical_bar_thick . "┃")
    (tree_branch . "├")
    (image . "\U000F02E9")
    (file . "\U000F0219")
    (audio . "")
    (location . "\U000F034E")
    (video . ""))
  "Default icons (Nerd Font glyphs).")

(defcustom neoment-icons neoment-default-icons
  "Icons used by Neoment, as an alist of (KEY . STRING).
Keys missing from this alist use the value in `neoment-default-icons'."
  :type '(alist :key-type symbol :value-type string))

(defun neoment-icon (key)
  "Return the icon string for KEY."
  (or (alist-get key neoment-icons)
      (alist-get key neoment-default-icons)
      ""))

(declare-function neoment-notify--message "neoment-notify")

(defconst neoment-config--choices
  '((neoment-login-method nil oauth_device password sso)
    (neoment-http-backend auto plz url)
    (neoment-rooms-display-last-message no message sender_message
                                        sender_message_inline)
    (neoment-rooms-room-title-format space_room room room_space))
  "Valid values of the options checked by `neoment-config-validate'.")

(defun neoment-config-validate ()
  "Check the user options and warn about invalid values.
Return non-nil when every option is valid."
  (let ((valid t))
    (pcase-dolist (`(,var . ,choices) neoment-config--choices)
      (let ((value (symbol-value var)))
        (unless (memq value choices)
          (setq valid nil)
          (display-warning
           'neoment
           (format "Invalid value for `%s': %S (expected one of %s)"
                   var value
                   (mapconcat (lambda (c) (format "%S" c)) choices ", "))
           :warning))))
    (dolist (var '(neoment-notifier neoment-desktop-notifications-handler
                   neoment-room-picker-function
                   neoment-open-room-picker-function
                   neoment-on-open-attachment-function))
      (unless (let ((f (symbol-value var)))
                (or (functionp f) (and f (symbolp f))))
        (setq valid nil)
        (display-warning 'neoment
                         (format "`%s' is not a function: %S"
                                 var (symbol-value var))
                         :warning)))
    valid))

;;;###autoload
(defun neoment-reload-config ()
  "Validate the user options again."
  (interactive)
  (require 'neoment-notify)
  (neoment-config-validate)
  (neoment-notify--message "Configuration reloaded"))

(provide 'neoment-config)
;;; neoment-config.el ends here
